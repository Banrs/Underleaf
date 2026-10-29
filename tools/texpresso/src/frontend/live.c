#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mupdf/fitz.h>
#include "editor.h"
#include "engine.h"
#include "mydvi.h"
#include "prot_parser.h"
#include "providers.h"
#include "vstack.h"

#define LIVE_PASSES 2
#define LIVE_SETTLE_MS 1000
#define LIVE_RERUN_MS 3000

typedef struct
{
  uint64_t now;
  uint64_t shown;
  uint64_t whole;
} live_page;

typedef struct
{
  fz_context *ctx;
  txp_engine *eng;
  const char *doc_path;
  const char *pdf_output;

  struct {
    int first, last;
    int mark;
    bool touched;
    bool scan;
    char caret_path[1024];
    int caret_offset;
  } wish;

  live_page *pages;
  int cap;
  int checked;
  uint64_t salt;
  int whole_pages;
  bool had_complete;
  bool whole_complete;
  bool dirty;
  int synced;
  bool started;
  bool tail;
  double changed_at;
  int run;
  bool aux;
  int passes;
} live_state;

static double live_ms(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static bool poll_input(void)
{
  struct pollfd fd = {STDIN_FILENO, POLLRDNORM, 0};
  return poll(&fd, 1, 0) == 1 && (fd.revents & (POLLRDNORM | POLLHUP)) != 0;
}

static fileentry_t *find_entry(live_state *l, const char *path, const char *verb)
{
  size_t n = strlen(l->doc_path);
  if (strncmp(path, l->doc_path, n) == 0 && path[n] == '/')
    path += n + 1;
  else if (path[0] == '/')
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
  if (changed >= 0)
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
      apply_open(l, cmd.open.path, cmd.open.data, cmd.open.length);
      break;

    case EDIT_CHANGE:
      l->wish.touched = true;
      apply_change(l, &cmd.change);
      break;

    case EDIT_RESCAN:
      l->wish.scan = true;
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

    default:
      break;
  }
}

static bool read_commands(live_state *l, prot_parser *parser, vstack *stack)
{
  char buffer[4096];
  int n = -1;
  while (poll_input() && (n = read(STDIN_FILENO, buffer, sizeof buffer)) != 0)
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

static void live_write_page(live_state *l, int index)
{
  fz_context *ctx = l->ctx;
  fz_buffer *pdf = NULL, *text = NULL;
  fz_document_writer *writer = NULL;
  fz_output *out = NULL;
  fz_var(pdf);
  fz_var(text);
  fz_var(writer);
  fz_var(out);
  fz_try(ctx)
  {
    pdf = fz_new_buffer(ctx, 64 * 1024);
    writer = fz_new_document_writer_with_buffer(ctx, pdf, "pdf", "");
    fz_device *dev = fz_begin_page(ctx, writer, txp_tex_page_box(l->eng, index));
    txp_tex_run_page(l->eng, ctx, index, dev);
    fz_end_page(ctx, writer);
    fz_close_document_writer(ctx, writer);
    text = fz_new_buffer(ctx, pdf->len / 3 * 4 + 4);
    out = fz_new_output_with_buffer(ctx, text);
    fz_write_base64_buffer(ctx, out, pdf, 0);
    fz_close_output(ctx, out);
    l->pages[index].shown = l->pages[index].now;
    editor_page(index, (const char *)text->data, text->len);
  }
  fz_always(ctx)
  {
    fz_drop_output(ctx, out);
    fz_drop_document_writer(ctx, writer);
    fz_drop_buffer(ctx, pdf);
    fz_drop_buffer(ctx, text);
  }
  fz_catch(ctx)
    fprintf(stderr, "[pdf] couldn't write page %d: %s\n", index, fz_caught_message(ctx));
}

static void live_scan(live_state *l, bool view)
{
  int count = send(page_count, l->eng);
  if (l->checked > count)
    l->checked = count;
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
      interrupted = interruptible && (i & 3) == 3 && poll_input();
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

static bool live_step(live_state *l, int count)
{
  double until = live_ms() + 4;
  for (int steps = 1; send(step, l->eng, l->ctx, false); steps++)
  {
    if (send(page_count, l->eng) != count || live_ms() > until ||
        ((steps & 15) == 0 && poll_input()))
      return send(get_status, l->eng) == DOC_RUNNING;
  }
  return false;
}

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
  l->whole_pages = -1;
  l->changed_at = -1e9;
  l->wish.last = 1;
  l->wish.caret_offset = -1;
  l->tail = true;
  editor_live(3);

  struct pollfd opening = {STDIN_FILENO, POLLRDNORM, 0};
  poll(&opening, 1, 100);
  if (read_commands(l, parser, stack))
    return;
  send(step, l->eng, ctx, true);

  bool running = true;
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
      if (l->started)
        l->changed_at = live_ms();
      l->passes = 0;
      l->tail = true;
    }

    bool stepping = send(get_status, l->eng) == DOC_RUNNING;
    int count = send(page_count, l->eng);
    bool rest = l->tail || (l->aux && l->passes < LIVE_PASSES);
    bool wanted = stepping && (count <= l->wish.last ||
                               (rest && live_ms() - l->changed_at >= LIVE_SETTLE_MS));
    bool more = wanted && live_step(l, count);
    txp_engine *eng = txp_tex_successor(l->eng, ctx);
    if (eng != l->eng)
    {
      l->eng = eng;
      l->checked = 0;
      more = true;
    }
    live_scan(l, first != l->wish.first || last != l->wish.last);
    stepping = send(get_status, l->eng) == DOC_RUNNING;
    count = send(page_count, l->eng);

    if (running && !stepping)
    {
      running = false;
      l->started = true;
      l->tail = false;
      l->run = txp_tex_outcome(l->eng);
      l->aux = l->run == RUN_COMPLETE && txp_tex_aux_changed(l->eng);
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
      if (l->whole_pages < 0 && count > l->wish.last &&
          live_write_whole(l, RUN_PARTIAL, false) == LIVE_FAILED)
        l->whole_pages = 0;
      if (!wanted && rest)
        wake = l->changed_at + LIVE_SETTLE_MS;
    }
    else if (!running)
    {
      bool completed = l->run == RUN_COMPLETE && !l->whole_complete;
      bool differs = (l->dirty || count != l->whole_pages || completed) &&
                     !(l->run == RUN_STOPPED && l->had_complete);
      double due = l->run == RUN_COMPLETE && (count != l->whole_pages || completed)
                       ? now : l->changed_at + LIVE_SETTLE_MS;
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

      double pass_due = l->changed_at + LIVE_RERUN_MS;
      if (l->aux && l->passes < LIVE_PASSES && now >= pass_due && !more)
      {
        l->passes++;
        fprintf(stderr, "[live] finishing pass %d\n", l->passes);
        txp_tex_rerun(l->eng, ctx);
        l->tail = true;
        running = true;
        more = true;
      }
      else if (l->aux && l->passes < LIVE_PASSES && (wake < 0 || pass_due < wake))
        wake = pass_due;
    }
    if (more || (!stepping && l->wish.caret_offset >= 0))
      continue;

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

static void live_mupdf_message(void *kind, const char *message)
{
  fprintf(stderr, "%s: %s\n", (const char *)kind, message);
}

static void usage(void)
{
  fprintf(stderr, "Usage: texpresso [-json] [-texlive] [-I dir]... main.tex\n"
                  "with TEXPRESSO_PDF_OUTPUT=<folder>/live.pdf\n");
}

static bool engine_path(const char *argv0, char path[PATH_MAX])
{
  char exe[PATH_MAX], real[PATH_MAX];
  uint32_t size = PATH_MAX;
  if (!(_NSGetExecutablePath(exe, &size) == 0 && realpath(exe, real)) && !realpath(argv0, real))
    return false;
  snprintf(path, PATH_MAX, "%.*s/texpresso-xetex", (int)(strrchr(real, '/') - real), real);
  return true;
}

static char diagnostics[1 << 15];

static void crashed(int sig)
{
  (void)sig;
  write(STDERR_FILENO, diagnostics, stderr->_p - (unsigned char *)diagnostics);
}

int main(int argc, const char **argv)
{
  setvbuf(stderr, diagnostics, _IOFBF, sizeof diagnostics);
  struct sigaction crash = {.sa_handler = crashed, .sa_flags = SA_RESETHAND};
  sigaction(SIGABRT, &crash, NULL);
  sigaction(SIGSEGV, &crash, NULL);
  sigaction(SIGBUS, &crash, NULL);
  const char *pdf_output = getenv("TEXPRESSO_PDF_OUTPUT");
  char engine[PATH_MAX];
  if (!engine_path(argv[0], engine))
  {
    perror("finding executable path");
    return 1;
  }

  const char *doc_arg = NULL;
  char inputs[8192] = "";
  for (int i = 1; i < argc; i++)
  {
    const char *arg = argv[i];
    if (!strcmp(arg, "-json") || !strcmp(arg, "-texlive"))
      ;
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
  if (chdir(doc_path) != 0)
    perror("chdir to the document's folder");

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
  l.eng = txp_tex_live_engine(ctx, engine, inputs, doc_name, doc_path);

  vstack *stack = vstack_new(ctx);
  prot_parser parser;
  prot_initialize(&parser, true);
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
  send(destroy, l.eng, ctx);
  dvi_drop_page_fonts(ctx);
  vstack_free(ctx, stack);
  fz_drop_context(ctx);
  return status;
}
