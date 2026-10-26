#ifndef TEXLOCAL_H
#define TEXLOCAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

typedef struct TlHandle TlHandle;

typedef void (*TlCallback)(void *_Nullable ctx, const char *json);

TlHandle *_Nullable tl_open(const char *_Nullable data_dir, TlCallback _Nullable listener, void *_Nullable ctx);

void tl_free(char *_Nullable text);

void tl_call_async(const TlHandle *handle, const char *command, const char *_Nullable args_json,
                   TlCallback _Nullable done, void *_Nullable ctx);

typedef struct TlSource TlSource;

TlSource *_Nullable tl_session_source(const TlHandle *handle, uint64_t session, const char *path);

TlSource *tl_source_new(const uint8_t *_Nullable text, size_t len);

typedef struct {
    uint32_t start;
    uint32_t length;
} TlRange;

char *_Nullable tl_source_edit(TlSource *source, uint32_t start, uint32_t length, const uint8_t *_Nullable text, size_t len,
                               const TlRange *_Nullable changing, bool mirroring);

void tl_source_select(TlSource *source, uint32_t start, uint32_t length, bool mirroring);

uint8_t *_Nullable tl_source_text(TlSource *source, size_t *_Nullable len);
void tl_source_free_text(uint8_t *_Nullable text, size_t len);

bool tl_source_reload(TlSource *source, const uint8_t *_Nullable text, size_t len);

uint32_t tl_source_line_at(TlSource *source, uint32_t offset);
uint32_t tl_source_line_start(TlSource *source, uint32_t line);
uint32_t tl_source_line_count(TlSource *source);

uint32_t *_Nullable tl_source_highlights(TlSource *source, uint32_t start, uint32_t length, size_t *_Nullable count);
void tl_source_free_runs(uint32_t *_Nullable runs, size_t count);

char *_Nullable tl_source_call(TlSource *source, const char *command, const char *args_json);

char *_Nullable tl_syntax_call(const char *command, const char *args_json);

void tl_source_free(TlSource *_Nullable source);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
