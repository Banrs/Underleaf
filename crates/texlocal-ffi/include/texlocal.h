/*
 * TeXLocal core C ABI.
 *
 * Commands: tl_send and tl_session_send return at once. Each id is answered once, later, through the listener
 * given to tl_open, as a reply carrying the caller's id. Session events, library sections and logs arrive the
 * same way.
 *
 * Listener: called on the core's own "texlocal-events" thread, one message at a time. The JSON pointer is
 * valid only during the call, so copy what you keep.
 *
 * Sources: TlSource calls are memory safe from any thread, since a mutex guards the text. Make them all from
 * the host's UI thread anyway, so edits apply in order and to the text the host shows. A call may block
 * briefly while the session reads the text.
 *
 * Text: offsets and lengths are UTF-16 code units; text passed in or out is UTF-8 bytes with a length.
 *
 * Ownership: free what the core returns with the function that pairs with it.
 *   tl_source_edit, tl_source_call, tl_syntax_call  ->  tl_free
 *   tl_source_text                                  ->  tl_source_free_text
 *   tl_source_highlights                            ->  tl_source_free_runs
 *   tl_session_source, tl_source_new                ->  tl_source_free
 */

#ifndef TEXLOCAL_H
#define TEXLOCAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

// The core, opened on the folders it keeps its data and state in; NULL if it can't use them.
typedef struct TlHandle TlHandle;

typedef void (*TlCallback)(void *_Nullable ctx, const char *json);

TlHandle *_Nullable tl_open(const char *_Nullable data_dir, const char *_Nullable state_dir,
                            const char *_Nullable helpers_dir, TlCallback _Nullable listener, void *_Nullable ctx);

void tl_free(char *_Nullable text);

// Asynchronous: the answer arrives through the listener with the same id.
void tl_send(const TlHandle *handle, uint64_t id, const char *command, const char *args_json);
void tl_session_send(const TlHandle *handle, uint64_t id, uint64_t session, const char *command,
                     const char *args_json);

// An open file's text, edited synchronously by the host's editor.
typedef struct TlSource TlSource;

// NULL unless the session has that path open.
TlSource *_Nullable tl_session_source(const TlHandle *handle, uint64_t session, const char *path);

// A source of no session, for text the host edits on its own.
TlSource *tl_source_new(const uint8_t *_Nullable text, size_t len);

typedef struct {
    uint32_t start;
    uint32_t length;
} TlRange;

// Answers with the mirrored edits, or an error if the document was closed.
char *tl_source_edit(TlSource *source, uint32_t start, uint32_t length, const uint8_t *_Nullable text, size_t len,
                     const TlRange *_Nullable changing, bool mirroring);

void tl_source_select(TlSource *source, uint32_t start, uint32_t length, bool mirroring);
void tl_source_composing(TlSource *source, bool composing);

uint8_t *_Nullable tl_source_text(TlSource *source, size_t *_Nullable len);
void tl_source_free_text(uint8_t *_Nullable text, size_t len);

void tl_source_restore(TlSource *source, const uint8_t *_Nullable text, size_t len);

bool tl_source_editable(TlSource *source);
uint64_t tl_source_version(TlSource *source);

// Lines are numbered from 1.
uint32_t tl_source_line_at(TlSource *source, uint32_t offset);
uint32_t tl_source_line_start(TlSource *source, uint32_t line);
uint32_t tl_source_line_count(TlSource *source);

// Runs of three: start, length and kind; count is the number of integers.
uint32_t *_Nullable tl_source_highlights(TlSource *source, uint32_t start, uint32_t length, size_t *_Nullable count);
void tl_source_free_runs(uint32_t *_Nullable runs, size_t count);

char *tl_source_call(TlSource *source, const char *command, const char *args_json);

// Syntax commands that need no source.
char *tl_syntax_call(const char *command, const char *args_json);

void tl_source_free(TlSource *_Nullable source);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
