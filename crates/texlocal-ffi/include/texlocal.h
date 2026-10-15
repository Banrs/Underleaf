/* TeXLocal core, for the macOS app. The service's calls are JSON in, JSON
 * out, with the command names and arguments the browser server uses. See
 * crates/texlocal-ffi/src/lib.rs for the contract. */
#ifndef TEXLOCAL_H
#define TEXLOCAL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A pointer may be NULL only where it is marked _Nullable. */
#pragma clang assume_nonnull begin

typedef struct TlHandle TlHandle;

/* Open the service over the library folder data_dir, a UTF-8 path the host
 * chooses. Returns NULL for a NULL data_dir, or on failure. */
TlHandle *_Nullable tl_open(const char *_Nullable data_dir);

/* Blocking; call off the UI thread. args_json may be NULL. Returns
 * {"ok": value} or {"error": message, "status": code}. Free with tl_free. */
char *_Nullable tl_call(const TlHandle *handle, const char *command, const char *_Nullable args_json);

void tl_free(char *_Nullable text);

/* Stops running compiles and live previews. No call may be in flight. */
void tl_close(TlHandle *_Nullable handle);

/* The source editor's mirror of a file's text (crates/texlocal-syntax).
 * Calls on one TlSource must not overlap: one thread at a time, as the Swift
 * main actor guarantees. That holds for the const queries too: the Rust
 * side takes the source mutably in every call. Offsets and lengths count UTF-16
 * units; lines count from 1. */
typedef struct TlSource TlSource;

/* Text is len bytes of UTF-8, so it may hold U+0000; bytes that aren't UTF-8
 * read as U+FFFD. Never NULL. A call that fails inside answers nothing, 0,
 * no runs or NULL. */
TlSource *tl_source_new(const uint8_t *_Nullable text, size_t len);

/* The editor replaced length units at start with text. */
void tl_source_edit(TlSource *source, uint32_t start, uint32_t length, const uint8_t *_Nullable text, size_t len);

uint32_t tl_source_line_at(const TlSource *source, uint32_t offset);
uint32_t tl_source_line_start(const TlSource *source, uint32_t line);
uint32_t tl_source_line_count(const TlSource *source);

/* The highlighted runs of the lines a range touches: start, length and kind
 * (HighlightKind's order) for each; *count is the number of values. Free
 * them with tl_source_free_runs, which takes NULL as nothing. A NULL count
 * gets NULL, so there is nothing to free. */
uint32_t *_Nullable tl_source_highlights(TlSource *source, uint32_t start, uint32_t length, size_t *_Nullable count);
void tl_source_free_runs(uint32_t *_Nullable runs, size_t count);

/* A command of texlocal_syntax's SourceDocument::call (crates/texlocal-syntax
 * src/call.rs), with a JSON object of arguments: "completions",
 * "toggle_comment", "indent", "set_heading", "insert_block", "insert_symbol",
 * "math_at", "text_styles", "not_prose", "text" and the rest it lists.
 * Returns the result's JSON, or NULL for an unknown command or arguments;
 * free it with tl_free.
 * "set_symbols" keeps the project's labels and citations, {"labels": [...],
 * "citations": [...]}, with the source, answering null: "completions" offers
 * them in \ref{ and \cite{ until they are set again. A new source has none. */
char *_Nullable tl_source_call(const TlSource *source, const char *command, const char *args_json);

void tl_source_free(TlSource *_Nullable source);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
