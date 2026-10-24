#ifndef LIVE_H_
#define LIVE_H_

/* TeXpresso for an editor with its own PDF view, writing pages beside
 * `pdf_output` (TEXPRESSO_PDF_OUTPUT's value): argv as the command line's
 * (-json, -I dir, main.tex), commands read from `in_fd` until it closes, messages
 * to the editor's output (editor.c), diagnostics to stderr. `exe_path` is a real
 * file: kpathsea's, or on the Mac the program beside which its TeX is. Returns
 * the exit status. */
int txp_live_main(int argc, const char *const *argv, const char *exe_path,
                  const char *pdf_output, int in_fd);

#endif
