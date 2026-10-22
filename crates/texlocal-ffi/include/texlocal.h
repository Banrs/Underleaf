/* TeXLocal core, for the native apps: macOS links the static library,
 * Windows loads the DLL. Calls are JSON in, JSON out; docs/core-api.md is the
 * contract, with every command and event. */
#ifndef TEXLOCAL_H
#define TEXLOCAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A pointer may be NULL only where it is marked _Nullable. */
#pragma clang assume_nonnull begin

typedef struct TlHandle TlHandle;

/* The service over the library folder data_dir, a UTF-8 path; NULL for a NULL
 * data_dir, or on failure. */
TlHandle *_Nullable tl_open(const char *_Nullable data_dir);

/* Blocking; call off the UI thread. Returns {"ok": value} or {"error": message,
 * "status": code}. Free with tl_free. */
char *tl_call(const TlHandle *handle, const char *command, const char *_Nullable args_json);

void tl_free(char *_Nullable text);

/* Called with the pointer it was given and a JSON text valid only during the
 * call, on a core thread: hop to the UI thread before touching the UI. */
typedef void (*TlCallback)(void *_Nullable ctx, const char *json);

/* tl_call without blocking: done gets the envelope tl_call would return; a NULL
 * done runs the command for its effect alone. A session's commands (every
 * session_* but session_open) are queued before this returns, so it takes them
 * in the order sent. */
void tl_call_async(const TlHandle *handle, const char *command, const char *_Nullable args_json,
                   TlCallback _Nullable done, void *_Nullable ctx);

/* The sessions' events, one JSON object at a time, in order, on one core
 * thread. NULL removes the listener, returning once no call to the previous
 * one is running. */
void tl_set_listener(const TlHandle *handle, TlCallback _Nullable listener, void *_Nullable ctx);

/* Closes the sessions, saving what they can, and stops compiles and live
 * previews. No call may be in flight; no listener call follows. */
void tl_close(TlHandle *_Nullable handle);

/* The source editor's view of a file's text. Calls on one TlSource must not
 * overlap, queries included. Offsets and lengths count UTF-16 units; lines
 * count from 1. A call that fails inside answers nothing: 0, no runs or NULL. */
typedef struct TlSource TlSource;

/* The document a session has open at path, NULL if none: its edits are the
 * session's, and its completions offer the project's labels and citations.
 * Each source starts with no typing state from an earlier one. Free with
 * tl_source_free, which leaves the document open. */
TlSource *_Nullable tl_session_source(const TlHandle *handle, uint64_t session, const char *path);

/* Text is len bytes of UTF-8, so it may hold U+0000; bytes that aren't UTF-8
 * read as U+FFFD. */
TlSource *tl_source_new(const uint8_t *_Nullable text, size_t len);

/* A range of the text, in UTF-16 units. */
typedef struct {
    uint32_t start;
    uint32_t length;
} TlRange;

/* The editor replaced length units at start with text, having said it would
 * change changing (NULL if no one range). Unless mirroring (the source's own
 * mirror edits going in), returns what was typed in a snippet's field for its
 * other places, a JSON array of edits from the last, or NULL for none; free it
 * with tl_free. */
char *_Nullable tl_source_edit(TlSource *source, uint32_t start, uint32_t length, const uint8_t *_Nullable text, size_t len,
                               const TlRange *_Nullable changing, bool mirroring);

/* The editor's (first) selection moved. */
void tl_source_select(TlSource *source, uint32_t start, uint32_t length, bool mirroring);

/* The whole text as *len bytes of UTF-8, not NUL-terminated; NULL for a NULL
 * len. Free with tl_source_free_text. */
uint8_t *_Nullable tl_source_text(TlSource *source, size_t *_Nullable len);
void tl_source_free_text(uint8_t *_Nullable text, size_t len);

/* The editor now shows text whole, as a document_reload event gave it: not an
 * edit to save. */
void tl_source_reload(TlSource *source, const uint8_t *_Nullable text, size_t len);

uint32_t tl_source_line_at(TlSource *source, uint32_t offset);
uint32_t tl_source_line_start(TlSource *source, uint32_t line);
uint32_t tl_source_line_count(TlSource *source);

/* The highlighted runs of the lines a range touches: start, length and kind
 * (HighlightKind's order) for each; *count is the number of values, NULL for
 * a NULL count. Free with tl_source_free_runs. */
uint32_t *_Nullable tl_source_highlights(TlSource *source, uint32_t start, uint32_t length, size_t *_Nullable count);
void tl_source_free_runs(uint32_t *_Nullable runs, size_t count);

/* A command of SourceDocument::call (crates/texlocal-core/src/syntax/call.rs),
 * or "version" for a session's document, with a JSON object of arguments. The
 * result's JSON, or NULL for an unknown command or arguments; free it with
 * tl_free. */
char *_Nullable tl_source_call(TlSource *source, const char *command, const char *args_json);

/* A command that needs no source, on any thread, answering as tl_source_call:
 * "themes", "theme_colors", "legible", "menus", "heading_styles", "drop_text"
 * (docs/core-api.md), and maths as SVG: "math_svg" {"tex", "display", "size"
 * (points, default 13), "color" ([r, g, b, a], 0-1, default black)} and
 * "glyph_svg" {"command", "size" (19), "side" (24), "color"} answer {"svg",
 * "width", "height"} in points, the SVG only <path> and <rect>, or
 * {"error": why}. */
char *_Nullable tl_syntax_call(const char *command, const char *args_json);

void tl_source_free(TlSource *_Nullable source);

#pragma clang assume_nonnull end

/* The TeX an app that can start no processes links (iPadOS: TeXpresso's engines,
 * tools/texpresso-ios), given once, before tl_open; without it, a build or Live
 * Preview there reports TeX as unavailable. Elsewhere it is unused. The fields
 * are txp_live_start, txp_session_wait and txp_run, typed as texpresso.h types
 * them (the session an incomplete struct, nothing marked for nullability), so
 * Swift takes those functions as they are. The struct is copied. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
typedef struct tl_engine {
    struct tl_engine_session *(*live_start)(int argc, const char *const *argv, const char *pdf_output,
                                            int *commands, int *messages, int *log);
    int (*session_wait)(struct tl_engine_session *session);
    int (*run)(const char *engine, int argc, const char *const *argv, const char *cwd, int output,
               const char *const *env, const volatile int *cancel);
} tl_engine;
#pragma clang diagnostic pop

void tl_set_engine(const tl_engine *_Nonnull engine);

#ifdef __cplusplus
}
#endif

#endif
