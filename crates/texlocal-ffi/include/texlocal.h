/* TeXLocal core, for the native apps: macOS links the static library,
 * Windows loads the DLL. The service's calls are JSON in, JSON out;
 * docs/core-api.md is the contract, with the project sessions' commands and
 * events. */
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

/* Open the service over the library folder data_dir, a UTF-8 path the host
 * chooses. Returns NULL for a NULL data_dir, or on failure. */
TlHandle *_Nullable tl_open(const char *_Nullable data_dir);

/* Blocking; call off the UI thread. args_json may be NULL. Returns
 * {"ok": value} or {"error": message, "status": code}. Free with tl_free. */
char *tl_call(const TlHandle *handle, const char *command, const char *_Nullable args_json);

void tl_free(char *_Nullable text);

/* A function the core calls with the pointer it was given and a JSON text,
 * valid only during the call, from a thread of the core's: hop to the UI
 * thread before touching the UI. */
typedef void (*TlCallback)(void *_Nullable ctx, const char *json);

/* tl_call without blocking: the command runs on a core thread, which then
 * calls done with the envelope tl_call would return. A NULL done runs the
 * command for its effect alone. A session's commands (every session_* but
 * session_open) are queued for it before this returns, so it takes them in
 * the order they were sent. */
void tl_call_async(const TlHandle *handle, const char *command, const char *_Nullable args_json,
                   TlCallback _Nullable done, void *_Nullable ctx);

/* The sessions' events, one JSON object at a time ({"type": ..., "session":
 * ..., ...}), in order, on one thread of the core's. NULL removes the
 * listener; returns once no call to the previous one is running. */
void tl_set_listener(const TlHandle *handle, TlCallback _Nullable listener, void *_Nullable ctx);

/* Closes the sessions, saving what they can, and stops running compiles and
 * live previews. No call may be in flight; no listener call follows. */
void tl_close(TlHandle *_Nullable handle);

/* The source editor's view of a file's text (the core's syntax module).
 * Calls on one TlSource must not overlap: one thread at a time, as the Swift
 * main actor guarantees, queries included. Offsets and lengths count UTF-16
 * units; lines count from 1. */
typedef struct TlSource TlSource;

/* The document a session has open at path (session_open_document): its
 * edits are the session's, which saves and previews them, and its
 * "completions" offer the project's labels and citations, which the session
 * scans. NULL if it isn't open. Free with tl_source_free, which leaves the
 * document open. Each source starts with no typing state: the brackets
 * closed for the user and a snippet's fields from an earlier visit are
 * forgotten. */
TlSource *_Nullable tl_session_source(const TlHandle *handle, uint64_t session, const char *path);

/* Text is len bytes of UTF-8, so it may hold U+0000; bytes that aren't UTF-8
 * read as U+FFFD. Never NULL. A call that fails inside answers nothing, 0,
 * no runs or NULL. */
TlSource *tl_source_new(const uint8_t *_Nullable text, size_t len);

/* A range of the text, in UTF-16 units. */
typedef struct {
    uint32_t start;
    uint32_t length;
} TlRange;

/* The editor replaced length units at start with text, having said it would
 * change changing (NULL if it said no one range). The closers typing put in
 * and a snippet's fields move with the edit. Unless mirroring (the source's
 * own mirror edits going in), returns what was typed in a snippet's field
 * for its other places, a JSON array of edits from the last, or NULL for
 * none, as nearly always; free it with tl_free. */
char *_Nullable tl_source_edit(TlSource *source, uint32_t start, uint32_t length, const uint8_t *_Nullable text, size_t len,
                               const TlRange *_Nullable changing, bool mirroring);

/* The editor's (first) selection moved: a snippet ends once it leaves the
 * fields, unless mirroring, and the closers before its line are no longer
 * stepped over. */
void tl_source_select(TlSource *source, uint32_t start, uint32_t length, bool mirroring);

/* The whole text as *len bytes of UTF-8, with no NUL after them (the text
 * may hold U+0000). Free with tl_source_free_text, which takes NULL as
 * nothing. A NULL len gets NULL. */
uint8_t *_Nullable tl_source_text(TlSource *source, size_t *_Nullable len);
void tl_source_free_text(uint8_t *_Nullable text, size_t len);

/* The editor now shows text whole, as a document_reload event gave it: not
 * an edit to save. */
void tl_source_reload(TlSource *source, const uint8_t *_Nullable text, size_t len);

uint32_t tl_source_line_at(TlSource *source, uint32_t offset);
uint32_t tl_source_line_start(TlSource *source, uint32_t line);
uint32_t tl_source_line_count(TlSource *source);

/* The highlighted runs of the lines a range touches: start, length and kind
 * (HighlightKind's order) for each; *count is the number of values. Free
 * them with tl_source_free_runs, which takes NULL as nothing. A NULL count
 * gets NULL, so there is nothing to free. */
uint32_t *_Nullable tl_source_highlights(TlSource *source, uint32_t start, uint32_t length, size_t *_Nullable count);
void tl_source_free_runs(uint32_t *_Nullable runs, size_t count);

/* A command of SourceDocument::call (crates/texlocal-core/src/syntax/call.rs),
 * with a JSON object of arguments: "completions", "toggle_comment",
 * "set_heading", "insert_block", "insert_symbol", "math_at", "text_styles",
 * "code_ranges" and the rest it lists, and for a session's document
 * "version". Returns the result's JSON, or NULL for an unknown command or
 * arguments; free it with tl_free. */
char *_Nullable tl_source_call(TlSource *source, const char *command, const char *args_json);

/* A command of the syntax module's call, which needs no source, on any thread:
 * "themes", "theme_colors", "legible" ({"color", "background", "fill",
 * "increaseContrast"?, "ratio"? (4.5, 7 with increaseContrast)}),
 * "menus", "heading_styles", "drop_text" ({"path", "kind",
 * "into"? ("tex")} answers {"insert": LaTeX} or {"open": true}, or null for a
 * folder), and maths as SVG:
 * "math_svg" {"tex", "display", "size" (points, default 13), "color" ([r, g,
 * b, a], 0-1, default black)} and "glyph_svg" {"command", "size" (19),
 * "side" (24), "color"} answer {"svg", "width", "height"} in points or
 * {"error": why}; the SVG holds only
 * <path> and <rect>. Returns the result's JSON, or NULL for an unknown
 * command or arguments; free it with tl_free. */
char *_Nullable tl_syntax_call(const char *command, const char *args_json);

void tl_source_free(TlSource *_Nullable source);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
