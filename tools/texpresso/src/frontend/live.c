/*
 * MIT License
 *
 * TeXpresso without a window, for an editor that shows the pages in its own PDF
 * view: the TEXPRESSO_PDF_OUTPUT mode of Underleaf's patches to TeXpresso, run by
 * the program's driver.c. It needs no SDL; engine_tex.c gives it its engine.
 *
 * The editor says which pages it shows (["view", first, last]). A change is
 * typeset as far as the last of them, and each page in view whose content
 * differs from what the editor was last given is written at once as a one-page
 * PDF of its own (["page", index, path]). The rest of the document follows
 * once typing pauses, in slices that a change interrupts. The whole document,
 * with its SyncTeX, is written when a run has reached the end and differs from
 * the one written before (["pdf", path, pages, run, changed]). Every message is
 * JSON, its first ["live", 2], the version of these shapes.
 *
 * References and contents come from finishing passes once the document has been
 * left alone for a moment, and only when a file TeX reads back (.aux, .toc) was
 * written other than as read. A pass is TeX again from the start, reading what
 * the last run wrote (txp_tex_rerun): a second TeX that takes the first one's
 * place once over, and that a change drops.
 */

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <mupdf/fitz.h>
#include "base64.h"
#include "editor.h"
#include "engine.h"
#include "live.h"
#include "mydvi.h"
#include "prot_parser.h"
#include "providers.h"
#include "vstack.h"

#define LIVE_PASSES 4

/* ms after a change: before the pages past the view are typeset, before the
 * whole document is written, and before a finishing pass starts. */
static int live_tail_ms = 150, live_whole_ms = 300, live_rerun_ms = 1000;

typedef struct
{
  uint64_t now;   // the page as typeset, by its bytes (pages below live.checked)
  uint64_t shown; // as the editor was last given it, in a page of its own or the document
  uint64_t whole; // as in the whole document last written
  int file[2];    // its own PDFs, by serial: the latest, and the one before it
} live_page;

typedef struct
{
  fz_context *ctx;
  txp_engine *eng;
  const char *doc_path; // the document's folder
  const char *pdf_output;
  bool paused;

  /* What the editor has asked for. */
  struct {
    int first, last;      // the pages it shows
    int mark;             // its last ["mark", n]
    bool touched;         // a command changed a file
    bool rerun;           // it asked for a finishing pass
    bool scan;            // it asked for the files on disk to be looked at again
    char caret_path[1024];
    int caret_offset;     // where its caret settled, -1 once a checkpoint is there
  } wish;

  live_page *pages;
  int cap;
  int checked;         // pages below this are compared since they were typeset
  int serial;          // of the last page file
  uint64_t salt;       // changes when a file on disk did: its pages are other pages
  int whole_pages;     // pages in the whole document last written, -1 before the first
  bool had_complete;   // a whole document of a run that reached the end was written
  bool whole_complete; // and the one last written is such a one
  bool dirty;          // a page differs from the whole document last written
  int synced;          // the last mark told as shown
  bool started;        // the first run is over
  double changed_at;   // when a file last changed, once it is
  int run;             // enum EDITOR_RUN: how the last run ended
  bool aux;            // and whether it wrote the files it reads other than as read
  int passes;          // finishing passes since the last change
  char dir[4096];
} live_state;

static double live_ms(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static int live_env(const char *name, int value)
{
  const char *text = getenv(name);
  return text && *text ? atoi(text) : value;
}

static bool poll_input(live_state *l)
{
  struct pollfd fd = {STDIN_FILENO, POLLRDNORM, 0};
  return poll(&fd, 1, 0) == 1 && (fd.revents & (POLLRDNORM | POLLHUP)) != 0;
}

/* Commands */

/* `path` relative to `dir`, and how many folders up from it (then not usable). */
static const char *relative_path(const char *path, const char *dir, int *go_up)
{
  size_t n = strlen(dir);
  *go_up = 0;
  if (strncmp(path, dir, n) == 0 && (path[n] == '/' || path[n] == 0))
  {
    path += n;
    while (*path == '/') path++;
    return path;
  }
  if (path[0] == '/')
    *go_up = 1;
  return path;
}

static fileentry_t *find_entry(live_state *l, const char *path, const char *verb)
{
  int go_up = 0;
  path = relative_path(path, l->doc_path, &go_up);
  if (go_up > 0)
  {
    fprintf(stderr, "[command] %s %s: file has a different root, skipping\n", verb, path);
    return NULL;
  }
  return send(find_file, l->eng, l->ctx, path);
}

static int find_diff(const fz_buffer *buf, const void *data, int size)
{
  const unsigned char *ptr = data;
  int i, len = fz_mini(buf->len, size);
  for (i = 0; i < len && buf->data[i] == ptr[i]; ++i);
  return i;
}

#include "utf_mapping.h"

/* Byte offset of `line` (0-based) in `b`, or -1. */
static int line_offset(fz_buffer *b, int line)
{
  int offset = 0;
  while (line > 0 && offset < (int)b->len)
    if (b->data[offset++] == '\n')
      line -= 1;
  return line > 0 ? -1 : offset;
}

static void apply_change(live_state *l, struct editor_change *op)
{
  fileentry_t *e = find_entry(l, op->path, "change");
  fz_buffer *b = e ? e->edit_data : NULL;
  if (!b)
  {
    fprintf(stderr, "[command] change %s: file not opened, skipping\n", op->path);
    return;
  }

  int offset = op->span.offset, remove = op->span.remove, length = op->length;
  if (op->base == BASE_LINE)
  {
    offset = line_offset(b, op->span.offset);
    int end = offset < 0 ? -1 : line_offset(b, op->span.offset + op->span.remove);
    if (end < 0 && offset >= 0) end = b->len;
    remove = end - offset;
  }
  else if (op->base == BASE_RANGE)
  {
    int start = line_offset(b, op->range.start_line);
    int stop = line_offset(b, op->range.end_line);
    if (start < 0 || stop < 0)
      offset = -1;
    else
    {
      int sc = utf16_to_utf8_offset(b->data + start, b->data + b->len, op->range.start_char);
      int ec = utf16_to_utf8_offset(b->data + stop, b->data + b->len, op->range.end_char);
      offset = sc < 0 ? -1 : start + sc;
      remove = ec < 0 ? -1 : stop + ec - offset;
    }
  }

  if (remove < 0 || offset < 0 || offset + remove > (int)b->len)
  {
    fprintf(stderr, "[command] change %s: invalid range, skipping\n", op->path);
    return;
  }
  if (b->len - remove + length > b->cap)
    fz_resize_buffer(l->ctx, b, b->len - remove + length + 128);
  memmove(b->data + offset + length, b->data + offset + remove, b->len - offset - remove);
  b->len = b->len - remove + length;
  memmove(b->data + offset, op->data, length);
  send(notify_file_changes, l->eng, l->ctx, e, offset);
}

static void apply_open(live_state *l, const char *path, const void *data, int size)
{
  fileentry_t *e = find_entry(l, path, "open");
  if (!e)
    return;

  int changed = -1;
  bool had_edit_data = e->edit_data != NULL;
  if (e->edit_data)
  {
    changed = find_diff(e->edit_data, data, size);
    if (changed == (int)e->edit_data->len && changed == size)
      changed = -1;
    if ((int)e->edit_data->cap < size)
      fz_resize_buffer(l->ctx, e->edit_data, size + 128);
    e->edit_data->len = size;
    memcpy(e->edit_data->data, data, size);
  }
  else
  {
    e->edit_data = fz_new_buffer_from_copied_data(l->ctx, data, size);
    if (e->fs_data)
      changed = find_diff(e->fs_data, data, size);
    else if (e->seen >= 0)
      changed = 0;
  }
  if (changed >= 0 && !(e->promised && !had_edit_data))
    send(notify_file_changes, l->eng, l->ctx, e, changed);
}

static void apply_close(live_state *l, const char *path)
{
  fileentry_t *e = find_entry(l, path, "close");
  if (!e || !e->edit_data)
    return;
  int changed = e->fs_data ? find_diff(e->fs_data, e->edit_data->data, e->edit_data->len) : 0;
  fz_drop_buffer(l->ctx, e->edit_data);
  e->edit_data = NULL;
  send(notify_file_changes, l->eng, l->ctx, e, changed);
}

static void interpret_command(live_state *l, vstack *stack, val command)
{
  struct editor_command cmd;
  if (!editor_parse(l->ctx, stack, command, &cmd))
    return;

  switch (cmd.tag)
  {
    case EDIT_OPEN:
      l->wish.touched = true;
      if (cmd.open.base64)
      {
        unsigned char *buf = malloc(cmd.open.length);
        if (!buf) break;
        memcpy(buf, cmd.open.data, cmd.open.length);
        int decoded = base64_decode(buf, cmd.open.length);
        if (decoded >= 0)
          apply_open(l, cmd.open.path, buf, decoded);
        free(buf);
      }
      else
        apply_open(l, cmd.open.path, cmd.open.data, cmd.open.length);
      break;

    case EDIT_CLOSE:
      l->wish.touched = true;
      apply_close(l, cmd.close.path);
      break;

    case EDIT_CHANGE:
      l->wish.touched = true;
      apply_change(l, &cmd.change);
      break;

    case EDIT_REGISTER:
    {
      fileentry_t *e = find_entry(l, cmd.reg.path, "register");
      if (e) e->promised = true;
      break;
    }

    case EDIT_RESCAN:
      l->wish.scan = true;
      break;

    case EDIT_PAUSE:
      l->paused = true;
      break;

    case EDIT_RESUME:
      l->paused = false;
      break;

    case EDIT_RERUN_ONCE:
      l->wish.rerun = true;
      break;

    case EDIT_VIEW:
      l->wish.first = fz_maxi(cmd.view.first, 0);
      l->wish.last = fz_maxi(cmd.view.last, l->wish.first);
      break;

    case EDIT_MARK:
      l->wish.mark = cmd.mark.serial;
      break;

    case EDIT_CARET:
      snprintf(l->wish.caret_path, sizeof l->wish.caret_path, "%s", cmd.caret.path);
      l->wish.caret_offset = fz_maxi(cmd.caret.offset, 0);
      break;

    default: // a window's: there is none
      break;
  }
}

/* Runs the commands waiting. Whether the input has closed. */
static bool read_commands(live_state *l, prot_parser *parser, vstack *stack)
{
  char buffer[4096];
  int n = -1;
  while (poll_input(l) && (n = read(STDIN_FILENO, buffer, sizeof buffer)) != 0)
  {
    if (n == -1)
    {
      if (errno == EINTR)
        continue;
      perror("read commands");
      return true;
    }
    const char *ptr = buffer, *lim = buffer + n;
    fz_try(l->ctx)
    {
      while ((ptr = prot_parse(l->ctx, parser, stack, ptr, lim)))
      {
        val cmds = vstack_get_values(l->ctx, stack);
        int n_cmds = val_array_length(l->ctx, stack, cmds);
        for (int i = 0; i < n_cmds; i++)
          interpret_command(l, stack, val_array_get(l->ctx, stack, cmds, i));
      }
    }
    fz_catch(l->ctx)
    {
      fprintf(stderr, "error while reading commands: %s\n", fz_caught_message(l->ctx));
      vstack_reset(l->ctx, stack);
      prot_reinitialize(parser);
    }
  }
  return n == 0;
}

/* Pages */

static live_page *live_at(live_state *l, int index)
{
  if (index >= l->cap)
  {
    int cap = l->cap ? l->cap : 64;
    while (cap <= index) cap *= 2;
    l->pages = fz_realloc_array(l->ctx, l->pages, cap, live_page);
    memset(l->pages + l->cap, 0, (cap - l->cap) * sizeof(live_page));
    l->cap = cap;
  }
  return &l->pages[index];
}

static void live_page_path(live_state *l, char *path, size_t size, int index, int serial)
{
  snprintf(path, size, "%s/page-%d-%d.pdf", l->dir, index, serial);
}

/* A page's own PDF is removed one step after another replaces it (`serial`, or 0
 * for the whole document): the editor may be about to read the one it was just
 * told of. */
static void live_retire(live_state *l, live_page *page, int index, int serial)
{
  char path[4200];
  if (page->file[1])
  {
    live_page_path(l, path, sizeof path, index, page->file[1]);
    remove(path);
  }
  page->file[1] = page->file[0];
  page->file[0] = serial;
}

static bool live_write_page(live_state *l, int index)
{
  fz_context *ctx = l->ctx;
  live_page *page = &l->pages[index];
  int serial = ++l->serial;
  char path[4200];
  live_page_path(l, path, sizeof path, index, serial);
  fz_document_writer *writer = NULL;
  fz_var(writer);
  fz_try(ctx)
  {
    writer = fz_new_pdf_writer(ctx, path, "");
    fz_device *dev = fz_begin_page(ctx, writer, txp_tex_page_box(l->eng, index));
    txp_tex_run_page(l->eng, ctx, index, dev);
    fz_end_page(ctx, writer);
    fz_close_document_writer(ctx, writer);
  }
  fz_always(ctx)
    fz_drop_document_writer(ctx, writer);
  fz_catch(ctx)
  {
    fprintf(stderr, "[pdf] couldn't write %s: %s\n", path, fz_caught_message(ctx));
    remove(path);
    return false;
  }
  live_retire(l, page, index, serial);
  page->shown = page->now;
  // Complete on disk before the editor hears of it.
  editor_page(index, path);
  return true;
}

/* Compares the pages typeset since the last look, and writes those in view that
 * differ from what the editor has; with `view`, first the earlier ones that have
 * come into view. */
static void live_scan(live_state *l, bool view)
{
  int count = send(page_count, l->eng);
  if (l->checked > count)
    l->checked = count;
  // Until the editor has a document, there is nothing for a page of its own to replace.
  bool pages = l->whole_pages >= 0;
  if (view && pages)
    for (int i = l->wish.first; i <= l->wish.last && i < l->checked; i++)
      if (l->pages[i].now != l->pages[i].shown)
        live_write_page(l, i);
  for (; l->checked < count; l->checked++)
  {
    int i = l->checked;
    live_page *page = live_at(l, i);
    page->now = txp_tex_page_hash(l->eng, i) ^ l->salt;
    if (page->now != page->whole)
      l->dirty = true;
    if (pages && i >= l->wish.first && i <= l->wish.last && page->now != page->shown)
      live_write_page(l, i);
  }
}

/* Without one to write, the last one goes: it would place the new pages' text
 * where the old ones had it. */
static void export_synctex(live_state *l)
{
  size_t len = strlen(l->pdf_output);
  if (len < 4 || len > 4000 || strcmp(l->pdf_output + len - 4, ".pdf"))
    return;
  char path[4200], part[4200];
  snprintf(path, sizeof path, "%.*s.synctex", (int)(len - 4), l->pdf_output);
  snprintf(part, sizeof part, "%s.part", path);
  fz_buffer *buf = NULL;
  send(synctex, l->eng, &buf);
  FILE *f = buf ? fopen(part, "wb") : NULL;
  bool written = f && fwrite(buf->data, 1, buf->len, f) == buf->len;
  if (f && fclose(f) != 0)
    written = false;
  if (!written || rename(part, path) != 0)
  {
    if (buf)
      fprintf(stderr, "[pdf] couldn't write %s\n", path);
    remove(part);
    remove(path);
  }
}

enum live_written { LIVE_WRITTEN, LIVE_INTERRUPTED, LIVE_FAILED };

/* The whole document as typeset so far, to the PDF output. `interruptible`, it
 * gives way to a command waiting: the next keystroke's page comes first. */
static enum live_written live_write_whole(live_state *l, int run, bool interruptible)
{
  fz_context *ctx = l->ctx;
  int pages = send(page_count, l->eng);
  char part[4200];
  snprintf(part, sizeof part, "%s.part", l->pdf_output);
  fz_document_writer *writer = NULL;
  bool interrupted = false;
  fz_var(writer);
  fz_var(interrupted);
  fz_try(ctx)
  {
    writer = fz_new_pdf_writer(ctx, part, "");
    for (int i = 0; i < pages && !interrupted; i++)
    {
      fz_device *dev = fz_begin_page(ctx, writer, txp_tex_page_box(l->eng, i));
      txp_tex_run_page(l->eng, ctx, i, dev);
      fz_end_page(ctx, writer);
      interrupted = interruptible && (i & 3) == 3 && poll_input(l);
    }
    if (!interrupted)
      fz_close_document_writer(ctx, writer);
  }
  fz_always(ctx)
    fz_drop_document_writer(ctx, writer);
  fz_catch(ctx)
  {
    fprintf(stderr, "[pdf] couldn't write %s: %s\n", part, fz_caught_message(ctx));
    remove(part);
    return LIVE_FAILED;
  }
  if (interrupted)
  {
    remove(part);
    return LIVE_INTERRUPTED;
  }
  // Its SyncTeX beside it, as live.synctex for live.pdf, for the editor's jumps
  // between source and pages; written first, so a PDF never comes without its own.
  export_synctex(l);
  if (rename(part, l->pdf_output) != 0)
  {
    perror("[pdf] rename");
    return LIVE_FAILED;
  }

  int *changed = fz_malloc_array(ctx, 2 * (pages + 1), int);
  int ranges = 0;
  for (int i = 0; i < l->cap; i++)
  {
    live_page *page = &l->pages[i];
    if (i < pages && page->now != page->whole)
    {
      if (ranges && changed[2 * ranges - 1] == i - 1)
        changed[2 * ranges - 1] = i;
      else
      {
        changed[2 * ranges] = changed[2 * ranges + 1] = i;
        ranges++;
      }
    }
    page->whole = page->shown = i < pages ? page->now : 0;
    live_retire(l, page, i, 0);
  }
  l->whole_pages = pages;
  l->dirty = false;
  l->whole_complete = run == RUN_COMPLETE;
  if (run == RUN_COMPLETE)
    l->had_complete = true;
  editor_pdf(l->pdf_output, pages, run, changed, ranges);
  fz_free(ctx, changed);
  return LIVE_WRITTEN;
}

/* Steps the engine until its page count leaves `count`, a few ms have passed, a
 * command waits, or it has nothing more to do yet: a worker's steps are short,
 * and the input is looked at every sixteenth. Whether it has more. */
static bool live_step(live_state *l, int count)
{
  double until = live_ms() + 4;
  for (int steps = 1; send(step, l->eng, l->ctx, false); steps++)
  {
    if (send(page_count, l->eng) != count || live_ms() > until ||
        ((steps & 15) == 0 && poll_input(l)))
      return send(get_status, l->eng) == DOC_RUNNING;
  }
  return false;
}

/* Where the editor's caret settled, a checkpoint is wanted just before it, so
 * that the first key typed there is as quick as the ones after it. A run that
 * hasn't read that far takes it on its way. One that is over is told of a change
 * there that changes nothing, and takes it as it does for a real change: the
 * pages typeset again are the same pages, and nothing is sent. A run in between
 * is left to end first. */
static void live_caret(live_state *l)
{
  int offset = l->wish.caret_offset, at;
  if (offset < 0)
    return;
  fileentry_t *e = find_entry(l, l->wish.caret_path, "caret"), *warm;
  bool running = send(get_status, l->eng) == DOC_RUNNING;
  if (!e || (txp_tex_warm(l->eng, &warm, &at) && warm == e && offset >= at && offset - at < 256) ||
      txp_tex_plant(l->eng, e, offset))
    l->wish.caret_offset = -1;
  else if (!running)
  {
    l->wish.caret_offset = -1;
    send(notify_file_changes, l->eng, l->ctx, e, offset);
  }
}

static void live_loop(live_state *l, prot_parser *parser, vstack *stack)
{
  fz_context *ctx = l->ctx;
  snprintf(l->dir, sizeof l->dir, "%s", l->pdf_output);
  char *slash = strrchr(l->dir, '/');
  if (slash)
    *slash = 0;
  else
    strcpy(l->dir, ".");
  l->whole_pages = -1;
  l->changed_at = -1e9;
  l->wish.last = 1;
  l->wish.caret_offset = -1;
  // For measuring.
  live_tail_ms = live_env("TEXPRESSO_LIVE_TAIL_MS", live_tail_ms);
  live_whole_ms = live_env("TEXPRESSO_LIVE_WHOLE_MS", live_whole_ms);
  live_rerun_ms = live_env("TEXPRESSO_LIVE_RERUN_MS", live_rerun_ms);
  editor_live(2);

  /* The editor's opening commands before the first run: a file it says it will
   * supply, or its own copy of one, must be there before TeX looks for it. */
  struct pollfd opening = {STDIN_FILENO, POLLRDNORM, 0};
  poll(&opening, 1, 100);
  if (read_commands(l, parser, stack))
    return;
  send(step, l->eng, ctx, true);

  bool running = true; // a run whose end hasn't been told
  for (;;)
  {
    int first = l->wish.first, last = l->wish.last;
    l->wish.touched = false;
    send(begin_changes, l->eng, ctx);
    if (read_commands(l, parser, stack))
      break;
    bool scanned = l->wish.scan;
    l->wish.scan = false;
    if (scanned)
      send(detect_changes, l->eng, ctx);
    live_caret(l);
    if (send(end_changes, l->eng, ctx))
    {
      if (!l->paused)
        send(step, l->eng, ctx, true);
      running = true;
      if (scanned)
      {
        l->wish.touched = true;
        l->salt += 0x9e3779b97f4a7c15ull;
      }
    }
    if (l->wish.touched)
    {
      // The files opened with the session aren't typing to wait out.
      if (l->started)
        l->changed_at = live_ms();
      l->passes = 0;
    }

    bool stepping = send(get_status, l->eng) == DOC_RUNNING && !l->paused;
    int count = send(page_count, l->eng);
    // Pages in view first; the rest once typing has paused.
    bool wanted = stepping && (count <= l->wish.last ||
                               live_ms() - l->changed_at >= live_tail_ms);
    bool more = wanted && live_step(l, count);
    txp_engine *eng = txp_tex_successor(l->eng, ctx);
    if (eng != l->eng)
    {
      // A pass's pages, all of them at once, which no look has seen.
      l->eng = eng;
      l->checked = 0;
      more = true;
    }
    live_scan(l, first != l->wish.first || last != l->wish.last);
    stepping = send(get_status, l->eng) == DOC_RUNNING && !l->paused;
    count = send(page_count, l->eng);

    if (running && !stepping && !l->paused)
    {
      running = false;
      l->started = true;
      l->run = txp_tex_outcome(l->eng);
      l->aux = l->run == RUN_COMPLETE && txp_tex_aux_changed(l->eng);
      if (!l->aux)
        l->wish.rerun = false;
      editor_done(l->run);
    }
    if (l->wish.mark != l->synced && (!stepping || count > l->wish.last))
    {
      l->synced = l->wish.mark;
      editor_synced(l->synced);
    }

    double now = live_ms(), wake = -1;
    if (stepping)
    {
      // Something to show before a long document is done.
      if (l->whole_pages < 0 && count > l->wish.last &&
          live_write_whole(l, RUN_PARTIAL, false) == LIVE_FAILED)
        l->whole_pages = 0;
      if (!wanted)
        wake = l->changed_at + live_tail_ms;
    }
    else if (!running)
    {
      // The early document, or one of a run that stopped, is told as complete
      // once it is, even with the same pages: the editor goes by what the last
      // one said.
      bool completed = l->run == RUN_COMPLETE && !l->whole_complete;
      // A run that stopped on an error doesn't replace a document that reached its end.
      bool differs = (l->dirty || count != l->whole_pages || completed) &&
                     !(l->run == RUN_STOPPED && l->had_complete);
      // Other pages wait for typing to pause; another number of them is told at once.
      double due = l->run == RUN_COMPLETE && (count != l->whole_pages || completed)
                       ? now : l->changed_at + live_whole_ms;
      if (differs && now >= due)
      {
        enum live_written written = live_write_whole(l, l->run, l->whole_pages >= 0);
        if (written == LIVE_INTERRUPTED)
          more = true;
        else if (written == LIVE_FAILED)
          l->dirty = false, l->whole_pages = count;
      }
      else if (differs)
        wake = due;

      if (l->wish.rerun)
        l->passes = fz_mini(l->passes, LIVE_PASSES - 1);
      double pass_due = l->wish.rerun ? now : l->changed_at + live_rerun_ms;
      if (l->aux && l->passes < LIVE_PASSES && now >= pass_due && !more)
      {
        l->wish.rerun = false;
        l->passes++;
        fprintf(stderr, "[live] finishing pass %d\n", l->passes);
        txp_tex_rerun(l->eng, ctx);
        running = true;
        more = true;
      }
      else if (l->aux && l->passes < LIVE_PASSES && (wake < 0 || pass_due < wake))
        wake = pass_due;
    }
    // A caret that waited for the run to end.
    if (more || (!stepping && l->wish.caret_offset >= 0))
      continue;

    // Nothing to do until a command comes, the worker has more, or one of the
    // pauses is over.
    fflush(stderr);
    struct pollfd fds[2] = {{STDIN_FILENO, POLLRDNORM, 0},
                            {stepping && wanted ? txp_tex_worker_fd(l->eng) : -1, POLLRDNORM, 0}};
    int timeout = wake < 0 ? -1 : fz_maxi((int)(wake - live_ms() + 0.999), 0);
    if (poll(fds, 2, timeout) == -1 && errno != EINTR)
      break;
    if ((fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) && !(fds[0].revents & POLLRDNORM))
      break;
  }
  fz_free(ctx, l->pages);
}

/* MuPDF's messages, which it gives the process's stderr, to the session's log. */
static void live_mupdf_message(void *kind, const char *message)
{
  fprintf(stderr, "%s: %s\n", (const char *)kind, message);
}

static void usage(void)
{
  fprintf(stderr, "Usage: texpresso [-json] [-texlive] [-I dir]... main.tex\n"
                  "with TEXPRESSO_PDF_OUTPUT=<folder>/live.pdf\n");
}

int txp_live_main(int argc, const char *const *argv, const char *exe_path,
                  const char *pdf_output)
{
  const char *doc_arg = NULL;
  char inputs[8192] = "";
  for (int i = 1; i < argc; i++)
  {
    const char *arg = argv[i];
    if (!strcmp(arg, "-json") || !strcmp(arg, "-texlive"))
      ; // what it speaks and reads either way
    else if (!strcmp(arg, "-I") && i + 1 < argc)
    {
      size_t n = strlen(inputs);
      snprintf(inputs + n, sizeof inputs - n, "%s%s", n ? ":" : "", argv[++i]);
    }
    else if (arg[0] != '-' && !doc_arg)
      doc_arg = arg;
    else
    {
      usage();
      return 1;
    }
  }
  if (!doc_arg || !pdf_output || !*pdf_output)
  {
    usage();
    return 1;
  }

  char doc_path[PATH_MAX];
  if (!realpath(doc_arg, doc_path))
  {
    perror("finding document path");
    return 1;
  }
  char *doc_name = strrchr(doc_path, '/');
  *doc_name++ = 0;

  editor_set_protocol(EDITOR_JSON);

  if (!texlive_available())
  {
    fprintf(stderr, "[fatal] no TeX Live tree: put kpsewhich on PATH, or set TEXPRESSO_LSR "
                    "to its ls-R files\n");
    return 1;
  }

  fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
  fz_set_warning_callback(ctx, live_mupdf_message, "warning");
  fz_set_error_callback(ctx, live_mupdf_message, "error");
  fz_register_document_handlers(ctx);
  live_state l = {.ctx = ctx, .doc_path = doc_path, .pdf_output = pdf_output};
  l.eng = txp_tex_live_engine(ctx, exe_path, doc_path, doc_name, inputs);

  vstack *stack = vstack_new(ctx);
  prot_parser parser;
  prot_initialize(&parser, true);
  dvi_page_fonts(ctx, true);
  int status = 0;
  fz_try(ctx)
  {
    live_loop(&l, &parser, stack);
  }
  fz_catch(ctx)
  {
    fprintf(stderr, "[fatal] %s\n", fz_caught_message(ctx));
    status = 1;
  }
  // The editor has gone (its pipe closed, even unexpectedly), or the session failed.
  send(destroy, l.eng, ctx);
  dvi_page_fonts(ctx, false);
  vstack_free(ctx, stack);
  fz_drop_context(ctx);
  return status;
}
