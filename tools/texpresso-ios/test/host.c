/* Runs TeXpresso in-process as the iPad app would, and times it: Live Preview of
 * <doc>/main.tex with edits to <doc>/body.tex, then Compile with pdfTeX into
 * <out>/compile, then a Stop of a Compile that computes without end. run-sim.sh
 * runs it in the simulator.
 *
 * host <doc folder> <out folder> */
#include <dirent.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "texpresso.h"

static double ms(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void footprint(const char *when)
{
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
    printf("memory %s: %.0f MB now, %.0f MB at most\n", when, info.phys_footprint / 1e6,
           info.ledger_phys_footprint_peak / 1e6);
}

static int messages, commands;
static char line[1 << 16];
static size_t held;

/* The next protocol line containing `what`, waiting at most `limit` ms; with
 * what NULL, lines until none comes for `limit` ms. Whether it came. */
static int await(const char *what, double limit)
{
  double end = ms() + limit;
  for (;;)
  {
    char *nl;
    while ((nl = memchr(line, '\n', held)))
    {
      *nl = 0;
      int found = what && strstr(line, what);
      if (found && getenv("HOST_VERBOSE")) printf("  %s\n", line);
      held -= nl + 1 - line;
      memmove(line, nl + 1, held);
      if (found) return 1;
      if (!what) end = ms() + limit;
    }
    struct pollfd fd = {messages, POLLIN, 0};
    int wait = (int)(end - ms());
    if (wait <= 0 || poll(&fd, 1, wait) <= 0) return 0;
    ssize_t n = read(messages, line + held, sizeof line - 1 - held);
    if (n <= 0) return 0;
    held += n;
  }
}

static void send(const char *text)
{
  write(commands, text, strlen(text));
}

static char *slurp(const char *path, size_t *size)
{
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(1); }
  fseek(f, 0, SEEK_END);
  *size = ftell(f);
  rewind(f);
  char *data = malloc(*size + 1);
  fread(data, 1, *size, f);
  data[*size] = 0;
  fclose(f);
  return data;
}

static char *json_string(const char *text)
{
  char *out = malloc(strlen(text) * 2 + 3), *o = out;
  *o++ = '"';
  for (; *text; text++)
  {
    if (*text == '\n') { *o++ = '\\'; *o++ = 'n'; continue; }
    if (*text == '"' || *text == '\\') *o++ = '\\';
    *o++ = *text;
  }
  *o++ = '"';
  *o = 0;
  return out;
}

static void *drain(void *fd)
{
  char buf[4096];
  int log = open(getenv("HOST_LOG") ? getenv("HOST_LOG") : "/dev/null",
                 O_WRONLY | O_CREAT | O_TRUNC, 0644);
  ssize_t n;
  while ((n = read((int)(intptr_t)fd, buf, sizeof buf)) > 0)
    write(log, buf, n);
  close(log);
  return NULL;
}

static void edit(const char *body, size_t offset, const char *text, int view, int mark)
{
  char cmd[8192];
  snprintf(cmd, sizeof cmd, "[\"view\", %d, %d]\n", view, view + 1);
  send(cmd);
  await(NULL, 300);
  char *quoted = json_string(text);
  snprintf(cmd, sizeof cmd, "[\"change\", \"%s\", %zu, 0, %s]\n[\"mark\", %d]\n", body, offset,
           quoted, mark);
  free(quoted);
  char pattern[32];
  snprintf(pattern, sizeof pattern, "[\"synced\", %d]", mark);
  double t = ms();
  send(cmd);
  int page = await("[\"page\"", 30000);
  double first = ms() - t;
  int synced = await(pattern, 30000);
  printf("edit on page %d: page %s in %.0f ms, synced %s at %.0f ms\n", view + 1,
         page ? "written" : "NOT written", first, synced ? "" : "NOT", ms() - t);
  await(NULL, 1500);
}

/* Compile: pdfTeX's format once into the cache, then the document twice, as a
 * build reruns for its references. */
static const char *doc_dir;

static void *compile(void *arg)
{
  const char *out = arg;
  char compile[1024], fmtdir[1024], fmtvar[1100], outdir[1100], result[1200];
  snprintf(compile, sizeof compile, "%s/compile", out);
  snprintf(fmtdir, sizeof fmtdir, "%s/formats", out);
  snprintf(fmtvar, sizeof fmtvar, "TEXFORMATS=%s", fmtdir);
  snprintf(outdir, sizeof outdir, "-output-directory=%s", compile);
  snprintf(result, sizeof result, "%s/main.pdf", compile);
  mkdir(compile, 0755);
  mkdir(fmtdir, 0755);
  int terminal = open(getenv("HOST_TEX_LOG") ? getenv("HOST_TEX_LOG") : "/dev/null",
                      O_WRONLY | O_CREAT | O_TRUNC, 0644);
  const char *env[] = {fmtvar, NULL};
  const char *ini[] = {"pdflatex", "-ini", "-etex", "-interaction=nonstopmode",
                       "-jobname=pdflatex", "pdflatex.ini"};
  double t = ms();
  int r = txp_run("pdftex", 6, ini, fmtdir, terminal, env, NULL);
  printf("compile: pdflatex.fmt made in %.0f ms (status %d)\n", ms() - t, r);
  const char *run[] = {"pdflatex", "-interaction=nonstopmode", "-synctex=1", outdir, "main.tex"};
  t = ms();
  r = txp_run("pdftex", 5, run, doc_dir, terminal, env, NULL);
  printf("compile: pdflatex in %.0f ms (status %d)\n", ms() - t, r);
  // BibTeX in the output folder, finding the document's .bib beside its source.
  char bibinputs[1100];
  snprintf(bibinputs, sizeof bibinputs, "BIBINPUTS=%s:", doc_dir);
  const char *bibenv[] = {bibinputs, NULL};
  const char *bib[] = {"bibtex", "main"};
  t = ms();
  r = txp_run("bibtex", 2, bib, compile, terminal, bibenv, NULL);
  printf("compile: bibtex in %.0f ms (status %d)\n", ms() - t, r);
  t = ms();
  r = txp_run("pdftex", 5, run, doc_dir, terminal, env, NULL);
  printf("compile: pdflatex again in %.0f ms (status %d)\n", ms() - t, r);
  struct stat st;
  int missing = stat(result, &st);
  printf("compile: %s %s (%lld bytes)\n", result, missing ? "MISSING" : "written",
         missing ? 0LL : (long long)st.st_size);

  // XeTeX writes XDV, which xdvipdfmx makes the PDF, as xelatex runs it. The
  // format is the one Live Preview made, in its cache.
  char xdv[1200], fmtpath[1100];
  snprintf(xdv, sizeof xdv, "%s/main.xdv", compile);
  const char *cache = getenv("TEXPRESSO_CACHE");
  DIR *dir = opendir(cache);
  struct dirent *d;
  while ((d = readdir(dir)) && strncmp(d->d_name, "xetex-", 6)) {}
  snprintf(fmtpath, sizeof fmtpath, "TEXFORMATS=%s/%s", cache, d ? d->d_name : "");
  closedir(dir);
  const char *xenv[] = {fmtpath, NULL};
  const char *xe[] = {"xelatex", "-no-pdf", "-interaction=nonstopmode", outdir, "main.tex"};
  t = ms();
  r = txp_run("xetex", 5, xe, doc_dir, terminal, xenv, NULL);
  printf("compile: xelatex -no-pdf in %.0f ms (status %d)\n", ms() - t, r);
  const char *dvipdf[] = {"xdvipdfmx", "-o", "main-xe.pdf", xdv};
  t = ms();
  r = txp_run("xdvipdfmx", 4, dvipdf, compile, terminal, NULL, NULL);
  snprintf(result, sizeof result, "%s/main-xe.pdf", compile);
  missing = stat(result, &st);
  printf("compile: xdvipdfmx in %.0f ms (status %d), %s %s (%lld bytes)\n", ms() - t, r, result,
         missing ? "MISSING" : "written", missing ? 0LL : (long long)st.st_size);
  close(terminal);
  return NULL;
}

static volatile int stop;
static double stopped_at;

static void *stop_later(void *arg)
{
  (void)arg;
  sleep(1);
  stopped_at = ms();
  stop = 1;
  return NULL;
}

int main(int argc, char **argv)
{
  if (argc != 3) { fprintf(stderr, "usage: host <doc> <out>\n"); return 2; }
  const char *doc = doc_dir = argv[1], *out = argv[2];
  char pdf[1024], build[1024], body[1024];
  snprintf(pdf, sizeof pdf, "%s/live.pdf", out);
  snprintf(build, sizeof build, "%s/build", out);
  snprintf(body, sizeof body, "%s/body.tex", doc);
  mkdir(out, 0755);
  chdir(doc);

  const char *args[] = {"texpresso", "-json", "-I", build, "main.tex"};
  int log;
  double t0 = ms();
  txp_session *s = txp_live_start(5, args, pdf, &commands, &messages, &log);
  if (!s) { fprintf(stderr, "no session\n"); return 1; }
  pthread_t logger;
  pthread_create(&logger, NULL, drain, (void *)(intptr_t)log);

  int shown = await("[\"pdf\"", 300000);
  printf("live: first pages %s at %.0f ms\n", shown ? "shown" : "NOT shown", ms() - t0);
  int done = await("[\"done\"", 300000);
  printf("live: first run %s at %.0f ms\n", done ? "done" : "NOT done", ms() - t0);
  await(NULL, 3000);
  printf("live: settled after its finishing passes at %.0f ms\n", ms() - t0 - 3000);
  footprint("after the first run");

  size_t size;
  char *text = slurp(body, &size);
  char *quoted = json_string(text);
  char *open_cmd = malloc(strlen(quoted) + strlen(body) + 32);
  sprintf(open_cmd, "[\"open\", \"%s\", %s]\n", body, quoted);
  send(open_cmd);
  free(open_cmd);
  free(quoted);
  await(NULL, 1000);

  size_t mid = strstr(text + size / 2, "\n\n") - text + 2;
  edit(body, mid, "Edited ", 4, 1);
  const char *word = "typing";
  for (int i = 0; word[i]; i++)
  {
    char key[2] = {word[i], 0};
    edit(body, mid + 7 + i, key, 4, 2 + i);
  }
  size_t early = strstr(text + 200, "\n\n") - text + 2;
  edit(body, early, "Early ", 1, 20);
  footprint("after the edits");

  /* Compile beside the session, as the app runs one while Live Preview is open:
   * another engine on another thread, with a key typed meanwhile. */
  pthread_t compiler;
  pthread_create(&compiler, NULL, compile, (void *)out);
  usleep(300000);
  edit(body, early + 6, "x", 1, 30);
  pthread_join(compiler, NULL);
  footprint("after Compile");

  close(commands);
  int status = txp_session_wait(s);
  pthread_join(logger, NULL);
  printf("live: ended with status %d\n", status);

  // A second session after the first, as when another project is opened.
  t0 = ms();
  s = txp_live_start(5, args, pdf, &commands, &messages, &log);
  pthread_create(&logger, NULL, drain, (void *)(intptr_t)log);
  held = 0;
  done = await("[\"done\"", 300000);
  printf("live again: first run %s at %.0f ms\n", done ? "done" : "NOT done", ms() - t0);
  close(commands);
  status = txp_session_wait(s);
  pthread_join(logger, NULL);
  printf("live again: ended with status %d\n", status);
  footprint("at the end");

  /* Stop: a Compile that computes without end, touching no file, cancelled after a second. */
  {
    char dir[1100], tex[1200], fmt[1100], fmtv[1200];
    snprintf(dir, sizeof dir, "%s/loop", out);
    snprintf(tex, sizeof tex, "%s/loop.tex", dir);
    snprintf(fmt, sizeof fmt, "%s/formats", out);
    snprintf(fmtv, sizeof fmtv, "TEXFORMATS=%s", fmt);
    mkdir(dir, 0755);
    FILE *f = fopen(tex, "w");
    fputs("\\def\\x{\\x}\\x\n", f);
    fclose(f);
    const char *loop_env[] = {fmtv, NULL};
    const char *loop[] = {"pdflatex", "-interaction=nonstopmode", "loop.tex"};
    pthread_t stopper;
    pthread_create(&stopper, NULL, stop_later, NULL);
    int r = txp_run("pdftex", 3, loop, dir, open("/dev/null", O_WRONLY), loop_env, &stop);
    printf("stop: status %d, %.0f ms after the cancel\n", r, ms() - stopped_at);
    pthread_join(stopper, NULL);
  }
  return 0;
}
