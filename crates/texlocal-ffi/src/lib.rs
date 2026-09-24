//! The C ABI the native apps link: one JSON-in, JSON-out call over
//! `texlocal_core::service`, the same command names and arguments the browser
//! server and the desktop frontend use. See `include/texlocal.h`.
//!
//! `tl_call` blocks until the command finishes (a compile can take minutes),
//! so hosts call it off their UI thread. Concurrent calls from several threads
//! are fine: each drives the handle's runtime on its own thread.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;

use serde_json::{json, Value};
use texlocal_core::service::Service;
use texlocal_core::{zipexport, CoreError};

pub struct TlHandle {
    runtime: tokio::runtime::Runtime,
    service: Service,
}

/// Commands only an in-process host may run. They take or return absolute
/// paths — fine for the app that owns this process, which is why they live
/// here and not in `Service::call`, which the browser server exposes.
fn native_call(service: &Service, command: &str, args: &Value) -> Option<Result<Value, CoreError>> {
    let s = |key: &str| {
        args.get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| CoreError::bad_request(format!("Invalid argument `{key}`")))
    };
    let path = |p: PathBuf| json!(p.to_string_lossy());
    Some(match command {
        "pdf_path" => s("id").and_then(|id| service.pdf_path(&id)).map(path),
        "raw_path" => (|| service.raw_path(&s("id")?, &s("path")?))().map(path),
        "export_zip" => (|| {
            let root = service.project_root(&s("id")?)?;
            zipexport::export_zip(&root, PathBuf::from(s("dest")?).as_path())?;
            Ok(Value::Null)
        })(),
        _ => return None,
    })
}

fn envelope(result: Result<Value, CoreError>) -> String {
    match result {
        Ok(value) => json!({ "ok": value }),
        Err(err) => json!({ "error": err.message, "status": err.status }),
    }
    .to_string()
}

fn into_c(text: String) -> *mut c_char {
    // JSON escapes NUL inside strings, so serialized output never contains one.
    CString::new(text)
        .expect("JSON has no interior NUL")
        .into_raw()
}

/// # Safety
/// `ptr` is null or a NUL-terminated string valid for the call.
unsafe fn str_arg<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

/// Open the service over `data_dir` (null for the default library). Returns
/// null if the directory cannot be created or the runtime cannot start.
///
/// # Safety
/// `data_dir` is null or a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn tl_open(data_dir: *const c_char) -> *mut TlHandle {
    let dir = match str_arg(data_dir) {
        Some(d) => PathBuf::from(d),
        None if data_dir.is_null() => texlocal_core::default_data_dir(),
        None => return std::ptr::null_mut(),
    };
    let opened = catch_unwind(|| {
        std::fs::create_dir_all(&dir).ok()?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .ok()?;
        Some(Box::new(TlHandle {
            runtime,
            service: Service::new(dir),
        }))
    });
    match opened {
        Ok(Some(handle)) => Box::into_raw(handle),
        _ => std::ptr::null_mut(),
    }
}

/// Run `command` with a JSON object of arguments (null means `{}`). Returns
/// `{"ok": value}` or `{"error": message, "status": code}`; free it with
/// `tl_free`.
///
/// # Safety
/// `handle` came from `tl_open` and is not closed; the strings are null or
/// NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn tl_call(
    handle: *const TlHandle,
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let Some(handle) = handle.as_ref() else {
        return into_c(envelope(Err(CoreError::bad_request("No handle"))));
    };
    let result = (|| {
        let command = str_arg(command).ok_or_else(|| CoreError::bad_request("Invalid command"))?;
        let args: Value = match str_arg(args_json) {
            Some(text) => serde_json::from_str(text)
                .map_err(|e| CoreError::bad_request(format!("Invalid JSON: {e}")))?,
            None if args_json.is_null() => json!({}),
            None => return Err(CoreError::bad_request("Arguments are not UTF-8")),
        };
        let service = &handle.service;
        catch_unwind(AssertUnwindSafe(|| {
            match native_call(service, command, &args) {
                Some(result) => result,
                None => handle.runtime.block_on(service.call(command, &args)),
            }
        }))
        .unwrap_or_else(|_| Err(CoreError::internal("The command panicked")))
    })();
    into_c(envelope(result))
}

/// Free a string `tl_call` returned. Null is ignored.
///
/// # Safety
/// `text` came from `tl_call` and is freed once.
#[no_mangle]
pub unsafe extern "C" fn tl_free(text: *mut c_char) {
    if !text.is_null() {
        drop(CString::from_raw(text));
    }
}

/// Stop every running compile and release the handle. Null is ignored.
///
/// # Safety
/// `handle` came from `tl_open`, no call on it is in flight, and it is closed
/// once.
#[no_mangle]
pub unsafe extern "C" fn tl_close(handle: *mut TlHandle) {
    if handle.is_null() {
        return;
    }
    let handle = Box::from_raw(handle);
    // Compiles run in their own process groups, so nothing else stops them.
    handle.service.compile.kill_all();
}
