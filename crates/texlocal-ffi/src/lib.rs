//! The C ABI the native apps link: one JSON-in, JSON-out call over
//! `texlocal_core::service`, the same command names and arguments the browser
//! server and the desktop frontend use. See `include/texlocal.h`.
//!
//! `tl_call` blocks until the command finishes (a compile can take minutes),
//! so hosts call it off their UI thread. Concurrent calls from several threads
//! are fine: each drives the handle's runtime on its own thread.
//!
//! `tl_source_*` are the native editors' own: `texlocal_syntax`'s mirror of
//! a file's text, answering in UTF-16 offsets, on the editor's thread.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::{json, Value};
use texlocal_core::service::{arg, Service};
use texlocal_core::{import, zipexport, CoreError};
use texlocal_syntax::{SourceDocument, TextRange};

pub struct TlHandle {
    runtime: tokio::runtime::Runtime,
    service: Service,
}

/// Commands only an in-process host may run. They take or return absolute
/// paths — fine for the app that owns this process, which is why they live
/// here and not in `Service::call`, which the browser server exposes.
fn native_call(service: &Service, command: &str, args: &Value) -> Option<Result<Value, CoreError>> {
    let s = |key: &str| arg::<String>(args, key);
    let path = |p: PathBuf| json!(p.to_string_lossy());
    Some(match command {
        "pdf_path" => (|| service.pdf_path(&s("id")?))().map(path),
        "raw_path" => (|| service.raw_path(&s("id")?, &s("path")?))().map(path),
        "project_root" => (|| service.project_root(&s("id")?))().map(path),
        "export_zip" => (|| {
            let root = service.project_root(&s("id")?)?;
            zipexport::export_zip(&root, Path::new(&s("dest")?))?;
            Ok(Value::Null)
        })(),
        // On quit, while a compile call may still be in flight — which rules
        // out tl_close — stop the latexmk trees that would otherwise outlive
        // the app.
        "kill_all" => {
            service.compile.kill_all();
            Ok(Value::Null)
        }
        "import_files" => (|| {
            let imported = import::import_files(
                service,
                &s("id")?,
                &arg::<Option<String>>(args, "dir")?.unwrap_or_default(),
                &arg::<Option<Vec<PathBuf>>>(args, "paths")?.unwrap_or_default(),
                arg(args, "conflict")?,
            )?;
            Ok(json!(imported))
        })(),
        "import_project" => (|| {
            let info = import::import_project(service, Path::new(&s("src")?))?;
            Ok(json!(info))
        })(),
        _ => return None,
    })
}

/// The result as a JSON envelope the host frees with `tl_free`.
fn reply(result: Result<Value, CoreError>) -> *mut c_char {
    let envelope = match result {
        Ok(value) => json!({ "ok": value }),
        Err(err) => json!({ "error": err.message, "status": err.status }),
    };
    // JSON escapes NUL inside strings, so serialized output never contains one.
    CString::new(envelope.to_string())
        .expect("JSON has no interior NUL")
        .into_raw()
}

/// # Safety
/// `ptr` is null or a NUL-terminated string valid for the call.
unsafe fn str_arg<'a>(ptr: *const c_char) -> Option<&'a str> {
    (!ptr.is_null()).then(|| CStr::from_ptr(ptr).to_str().ok())?
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
        return reply(Err(CoreError::bad_request("No handle")));
    };
    reply((|| {
        let command = str_arg(command).ok_or_else(|| CoreError::bad_request("Invalid command"))?;
        let args: Value = match str_arg(args_json) {
            Some(text) => serde_json::from_str(text)
                .map_err(|e| CoreError::bad_request(format!("Invalid JSON: {e}")))?,
            None if args_json.is_null() => json!({}),
            None => return Err(CoreError::bad_request("Arguments are not UTF-8")),
        };
        let service = &handle.service;
        catch_unwind(AssertUnwindSafe(|| {
            native_call(service, command, &args)
                .unwrap_or_else(|| handle.runtime.block_on(service.call(command, &args)))
        }))
        .unwrap_or_else(|_| Err(CoreError::internal("The command panicked")))
    })())
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

/// A file's text as the editor has it (`texlocal_syntax::SourceDocument`).
pub struct TlSource(SourceDocument);

/// # Safety
/// `text` is null (empty) or a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn tl_source_new(text: *const c_char) -> *mut TlSource {
    let text = str_arg(text).unwrap_or_default();
    Box::into_raw(Box::new(TlSource(SourceDocument::new(text))))
}

/// The editor replaced `length` units at `start` with `text`.
///
/// # Safety
/// `source` came from `tl_source_new` and is not freed; `text` is null
/// (nothing) or a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn tl_source_edit(
    source: *mut TlSource,
    start: u32,
    length: u32,
    text: *const c_char,
) {
    (*source)
        .0
        .edit(start, length, str_arg(text).unwrap_or_default());
}

/// # Safety
/// As `tl_source_edit`.
#[no_mangle]
pub unsafe extern "C" fn tl_source_line_at(source: *const TlSource, offset: u32) -> u32 {
    (*source).0.line_at(offset)
}

/// # Safety
/// As `tl_source_edit`.
#[no_mangle]
pub unsafe extern "C" fn tl_source_line_start(source: *const TlSource, line: u32) -> u32 {
    (*source).0.line_start(line)
}

/// # Safety
/// As `tl_source_edit`.
#[no_mangle]
pub unsafe extern "C" fn tl_source_line_count(source: *const TlSource) -> u32 {
    (*source).0.line_count()
}

/// The highlighted runs of the lines a range touches, as start, length and
/// kind (`HighlightKind`'s order) for each; `count` is the number of values.
/// Free them with `tl_source_free_runs`.
///
/// # Safety
/// As `tl_source_edit`; `count` is valid for a write.
#[no_mangle]
pub unsafe extern "C" fn tl_source_highlights(
    source: *mut TlSource,
    start: u32,
    length: u32,
    count: *mut usize,
) -> *mut u32 {
    let runs: Box<[u32]> = (*source)
        .0
        .highlights(start, length)
        .into_iter()
        .flat_map(|h| [h.start, h.length, h.kind as u32])
        .collect();
    *count = runs.len();
    Box::into_raw(runs).cast()
}

/// # Safety
/// `runs` and `count` came from one `tl_source_highlights`, freed once.
#[no_mangle]
pub unsafe extern "C" fn tl_source_free_runs(runs: *mut u32, count: usize) {
    drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
        runs, count,
    )));
}

/// The arguments the source's commands take, each what it needs.
#[derive(Deserialize, Default)]
#[serde(default)]
struct SourceArgs {
    caret: u32,
    explicit: bool,
    labels: Vec<String>,
    citations: Vec<String>,
    command: String,
    id: String,
    selection: TextRange,
    selections: Vec<TextRange>,
}

/// The editing commands, as `texlocal_syntax::SourceDocument` has them:
/// "completions", "toggle_comment", "set_heading", "insert_block",
/// "insert_symbol", "math_at" and "text". Returns the result's JSON (free it with
/// `tl_free`), or null for an unknown command or arguments.
///
/// # Safety
/// As `tl_source_edit`; the strings are null or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn tl_source_call(
    source: *const TlSource,
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let doc = &(*source).0;
    let Some(a) = str_arg(args_json).and_then(|a| serde_json::from_str::<SourceArgs>(a).ok())
    else {
        return std::ptr::null_mut();
    };
    let result = match str_arg(command).unwrap_or_default() {
        "completions" => json!(doc.completions(a.caret, a.explicit, &a.labels, &a.citations)),
        "toggle_comment" => json!(doc.toggle_comment(&a.selections)),
        "set_heading" => json!(doc.set_heading(a.caret, &a.command)),
        "insert_block" => json!(doc.insert_block(&a.id, a.selection)),
        "insert_symbol" => json!(doc.insert_symbol(&a.command, a.selection)),
        "math_at" => json!(doc.math_at(a.caret)),
        "text" => json!(doc.text()),
        _ => return std::ptr::null_mut(),
    };
    CString::new(result.to_string())
        .expect("JSON has no interior NUL")
        .into_raw()
}

/// Null is ignored.
///
/// # Safety
/// `source` came from `tl_source_new` and is freed once.
#[no_mangle]
pub unsafe extern "C" fn tl_source_free(source: *mut TlSource) {
    if !source.is_null() {
        drop(Box::from_raw(source));
    }
}
