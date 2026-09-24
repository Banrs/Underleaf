/* TeXLocal core, for the native apps. Every call is JSON in, JSON out, with
 * the command names and arguments the browser server uses. See
 * crates/texlocal-ffi/src/lib.rs for the contract. */
#ifndef TEXLOCAL_H
#define TEXLOCAL_H

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

#ifdef __cplusplus
}
#endif

#endif
