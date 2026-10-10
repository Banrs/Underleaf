/* TeXLocal core, for the native apps. The service's calls are JSON in, JSON
 * out, with the command names and arguments the browser server uses. See
 * crates/texlocal-ffi/src/lib.rs for the contract. */
#ifndef TEXLOCAL_H
#define TEXLOCAL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TlHandle TlHandle;

/* Open the service over data_dir (NULL: TEXLOCAL_DATA, else ~/TeXLocal).
 * Returns NULL on failure. */
TlHandle *tl_open(const char *data_dir);

/* Blocking; call off the UI thread. args_json may be NULL. Returns
 * {"ok": value} or {"error": message, "status": code}. Free with tl_free. */
char *tl_call(const TlHandle *handle, const char *command, const char *args_json);

void tl_free(char *text);

/* Stops running compiles. No call may be in flight. */
void tl_close(TlHandle *handle);

/* The source editor's mirror of a file's text (crates/texlocal-syntax), on
 * the editor's thread. Offsets and lengths count UTF-16 units; lines count
 * from 1. */
typedef struct TlSource TlSource;

/* Text is len bytes of UTF-8, so it may hold U+0000; bytes that aren't UTF-8
 * read as U+FFFD. No call into the core lets a Rust panic unwind into the
 * caller: each answers as the comments here say for bad input. */
TlSource *tl_source_new(const uint8_t *text, size_t len);

/* The editor replaced length units at start with text. */
void tl_source_edit(TlSource *source, uint32_t start, uint32_t length, const uint8_t *text, size_t len);

uint32_t tl_source_line_at(const TlSource *source, uint32_t offset);
uint32_t tl_source_line_start(const TlSource *source, uint32_t line);
uint32_t tl_source_line_count(const TlSource *source);

/* The highlighted runs of the lines a range touches: start, length and kind
 * (HighlightKind's order) for each; *count is the number of values. Free
 * them with tl_source_free_runs. NULL, *count 0, on an internal error. */
uint32_t *tl_source_highlights(TlSource *source, uint32_t start, uint32_t length, size_t *count);
void tl_source_free_runs(uint32_t *runs, size_t count);

/* "completions", "toggle_comment", "indent", "set_heading", "insert_block",
 * "insert_symbol", "math_at", "text_styles", "not_prose" or "text", with a
 * JSON object of arguments. Returns the result's JSON, or NULL for an unknown
 * command or arguments (or an internal error); free it with tl_free. */
char *tl_source_call(const TlSource *source, const char *command, const char *args_json);

void tl_source_free(TlSource *source);

#ifdef __cplusplus
}
#endif

#endif
