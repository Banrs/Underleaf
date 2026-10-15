/* TeXLocal core, for the native apps: macOS links the static library,
 * Windows loads the DLL. The service's calls are JSON in, JSON out, with the
 * command names and arguments the browser server uses; docs/core-api.md is
 * the contract, with the project sessions' commands and events. */
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

/* A function the core calls with the pointer it was given and a JSON text,
 * valid only during the call, from a thread of the core's: hop to the UI
 * thread before touching the UI. */
typedef void (*TlCallback)(void *_Nullable ctx, const char *json);

/* tl_call without blocking: the command runs on a core thread, which then
 * calls done with the envelope tl_call would return. A NULL done runs the
 * command for its effect alone. */
void tl_call_async(const TlHandle *handle, const char *command, const char *_Nullable args_json,
                   TlCallback _Nullable done, void *_Nullable ctx);

/* The sessions' events, one JSON object at a time ({"type": ..., "session":
 * ..., ...}), in order, on one thread of the core's. NULL removes the
 * listener; returns once no call to the previous one is running. */
void tl_set_listener(const TlHandle *handle, TlCallback _Nullable listener, void *_Nullable ctx);

/* Closes the sessions, saving what they can, and stops running compiles and
 * live previews. No call may be in flight; no listener call follows. */
void tl_close(TlHandle *_Nullable handle);

/* The source editor's view of a file's text (crates/texlocal-syntax).
 * Calls on one TlSource must not overlap: one thread at a time, as the Swift
 * main actor guarantees. That holds for the const queries too: the Rust
 * side takes the source mutably in every call. Offsets and lengths count UTF-16
 * units; lines count from 1. */
typedef struct TlSource TlSource;

/* The document a session has open at path (session_open_document): its
 * edits are the session's, which saves and previews them, and "set_symbols"
 * does nothing, as the session sets them. NULL if it isn't open. Free with
 * tl_source_free, which leaves the document open. */
TlSource *_Nullable tl_session_source(const TlHandle *handle, uint64_t session, const char *path);

/* Text is len bytes of UTF-8, so it may hold U+0000; bytes that aren't UTF-8
 * read as U+FFFD. Never NULL. A call that fails inside answers nothing, 0,
 * no runs or NULL. */
TlSource *tl_source_new(const uint8_t *_Nullable text, size_t len);

/* The editor replaced length units at start with text. */
void tl_source_edit(TlSource *source, uint32_t start, uint32_t length, const uint8_t *_Nullable text, size_t len);

/* The editor now shows text whole, as a document_reload event gave it: not
 * an edit to save. */
void tl_source_reload(TlSource *source, const uint8_t *_Nullable text, size_t len);

uint32_t tl_source_line_at(const TlSource *source, uint32_t offset);
uint32_t tl_source_line_start(const TlSource *source, uint32_t line);
uint32_t tl_source_line_count(const TlSource *source);

/* The highlighted runs of the lines a range touches: start, length and kind
 * (HighlightKind's order) for each; *count is the number of values. Free
 * them with tl_source_free_runs, which takes NULL as nothing. A NULL count
 * gets NULL, so there is nothing to free. */
uint32_t *_Nullable tl_source_highlights(TlSource *source, uint32_t start, uint32_t length, size_t *_Nullable count);
void tl_source_free_runs(uint32_t *_Nullable runs, size_t count);

/* "completions", "toggle_comment", "indent", "set_heading", "insert_block",
 * "insert_symbol", "math_at", "text_styles", "not_prose" or "text", with a
 * JSON object of arguments. Returns the result's JSON, or NULL for an unknown
 * command or arguments; free it with tl_free.
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
