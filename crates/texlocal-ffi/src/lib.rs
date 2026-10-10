//! The C ABI the native apps link: one JSON-in, JSON-out call over
//! `texlocal_core::service`, the same command names and arguments the browser
//! server uses. See `include/texlocal.h`.
//!
//! `tl_call` blocks until the command finishes (a compile can take minutes),
//! so hosts call it off their UI thread. Concurrent calls from several threads
//! are fine: each drives the handle's runtime on its own thread.
//!
//! `tl_source_*` are the native editors' own: `texlocal_syntax`'s mirror of
//! a file's text, answering in UTF-16 offsets, on the editor's thread.

use std::borrow::Cow;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use texlocal_core::service::{arg, string_arg, Service};
use texlocal_core::{import, zipexport, CoreError};
use texlocal_syntax::{SourceDocument, TextRange};

pub struct TlHandle {
    runtime: tokio::runtime::Runtime,
    service: Service,
}

impl TlHandle {
    /// Absolute-path commands belong to the in-process host. Only the shared
    /// commands are forwarded to `Service::call`, which the browser exposes.
    fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        let service = &self.service;
        let s = |key: &str| string_arg(args, key);
        let path = |p: PathBuf| json!(p.to_string_lossy());
        match command {
            "pdf_path" => service.pdf_path(s("id")?).map(path),
            "raw_path" => service.raw_path(s("id")?, s("path")?).map(path),
            "project_root" => service.project_root(s("id")?).map(path),
            "export_zip" => {
                let root = service.project_root(s("id")?)?;
                zipexport::export_zip(&root, Path::new(s("dest")?))?;
                Ok(Value::Null)
            }
            // On quit, while a compile call may still be in flight — which rules
            // out tl_close — stop the latexmk trees that would otherwise outlive
            // the app.
            "kill_all" => {
                service.compile.kill_all();
                service.texpresso.kill_all();
                Ok(Value::Null)
            }
            "import_files" => Ok(json!(import::import_files(
                service,
                s("id")?,
                &arg::<Option<String>>(args, "dir")?.unwrap_or_default(),
                &arg::<Option<Vec<PathBuf>>>(args, "paths")?.unwrap_or_default(),
                arg(args, "conflict")?,
            )?)),
            "import_project" => Ok(json!(import::import_project(
                service,
                Path::new(s("src")?)
            )?)),
            _ => self.runtime.block_on(service.call(command, args)),
        }
    }
}

/// `body`'s result, or none if it panicked: no panic may unwind into the
/// host, which would abort the app and lose the user's unsaved text. Only
/// the entry points that can't panic (making a source, freeing) go without.
fn caught<T>(body: impl FnOnce() -> T) -> Option<T> {
    catch_unwind(AssertUnwindSafe(body)).ok()
}

/// What a call on a source answers: `none` for a null source or a panic.
///
/// # Safety
/// `source` is null or came from `tl_source_new` and is not freed, and no
/// two calls on it overlap: one thread at a time, `const` queries included,
/// as `body` gets `&mut` (the host's `const` only marks those that leave the
/// text as it is).
unsafe fn on_source<T>(
    source: *const TlSource,
    none: T,
    body: impl FnOnce(&mut SourceDocument) -> T,
) -> T {
    match source.cast_mut().as_mut() {
        Some(source) => caught(|| body(&mut source.0)).unwrap_or(none),
        None => none,
    }
}

fn json_string(value: impl Serialize) -> *mut c_char {
    // JSON escapes NUL inside strings, so serialized output never contains one.
    CString::new(serde_json::to_string(&value).expect("command results serialize"))
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
    caught(|| {
        std::fs::create_dir_all(&dir).ok()?;
        let runtime = tokio::runtime::Runtime::new().ok()?;
        Some(Box::new(TlHandle {
            runtime,
            service: Service::new(dir),
        }))
    })
    .flatten()
    .map_or(std::ptr::null_mut(), Box::into_raw)
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
    let result = caught(|| {
        let handle = handle
            .as_ref()
            .ok_or_else(|| CoreError::bad_request("No handle"))?;
        let command = str_arg(command).ok_or_else(|| CoreError::bad_request("Invalid command"))?;
        let args: Value = match str_arg(args_json) {
            Some(text) => serde_json::from_str(text)
                .map_err(|e| CoreError::bad_request(format!("Invalid JSON: {e}")))?,
            None if args_json.is_null() => json!({}),
            None => return Err(CoreError::bad_request("Arguments are not UTF-8")),
        };
        handle.call(command, &args)
    })
    .unwrap_or_else(|| Err(CoreError::internal("The command panicked")));
    json_string(match result {
        Ok(value) => json!({ "ok": value }),
        Err(err) => json!({ "error": err.message, "status": err.status }),
    })
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
    // Dropping the runtime and the service is guarded too.
    caught(move || {
        handle.service.compile.kill_all();
        handle.service.texpresso.kill_all();
        drop(handle);
    });
}

/// A file's text as the editor has it (`texlocal_syntax::SourceDocument`).
pub struct TlSource(SourceDocument);

/// UTF-8 text by its byte count, so a U+0000 in the editor's text reaches
/// the mirror. Bytes that aren't UTF-8 read as U+FFFD, as Swift decodes
/// them, so an edit still lands with the length the editor has.
unsafe fn text_arg<'a>(ptr: *const u8, len: usize) -> Cow<'a, str> {
    if ptr.is_null() {
        return Cow::Borrowed("");
    }
    String::from_utf8_lossy(std::slice::from_raw_parts(ptr, len))
}

/// Never null: reading the text into lines can't fail.
///
/// # Safety
/// `text` is null (empty) or `len` bytes of UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tl_source_new(text: *const u8, len: usize) -> *mut TlSource {
    Box::into_raw(Box::new(TlSource(SourceDocument::new(&text_arg(
        text, len,
    )))))
}

/// The editor replaced `length` units at `start` with `text`. Each call on
/// a source answers as for a null source if it fails: nothing, 0, no runs.
///
/// # Safety
/// `source` came from `tl_source_new` and is not freed, and no other call
/// on it (`const` queries included) overlaps this one; `text` is null
/// (nothing) or `len` bytes of UTF-8.
#[no_mangle]
pub unsafe extern "C" fn tl_source_edit(
    source: *mut TlSource,
    start: u32,
    length: u32,
    text: *const u8,
    len: usize,
) {
    on_source(source, (), |doc| {
        doc.edit(start, length, &text_arg(text, len))
    });
}

/// # Safety
/// As `tl_source_edit`.
#[no_mangle]
pub unsafe extern "C" fn tl_source_line_at(source: *const TlSource, offset: u32) -> u32 {
    on_source(source, 0, |doc| doc.line_at(offset))
}

/// # Safety
/// As `tl_source_edit`.
#[no_mangle]
pub unsafe extern "C" fn tl_source_line_start(source: *const TlSource, line: u32) -> u32 {
    on_source(source, 0, |doc| doc.line_start(line))
}

/// # Safety
/// As `tl_source_edit`.
#[no_mangle]
pub unsafe extern "C" fn tl_source_line_count(source: *const TlSource) -> u32 {
    on_source(source, 0, |doc| doc.line_count())
}

/// The highlighted runs of the lines a range touches, as start, length and
/// kind (`HighlightKind`'s order) for each; `count` is the number of values.
/// Free them with `tl_source_free_runs`. A null `count` gets null, as runs
/// could not be freed without their count.
///
/// # Safety
/// As `tl_source_edit`; `count` is null or valid for a write.
#[no_mangle]
pub unsafe extern "C" fn tl_source_highlights(
    source: *mut TlSource,
    start: u32,
    length: u32,
    count: *mut usize,
) -> *mut u32 {
    let Some(count) = count.as_mut() else {
        return std::ptr::null_mut();
    };
    let runs: Box<[u32]> = on_source(source, Box::default(), |doc| {
        let runs = doc.highlights(start, length).into_iter();
        runs.flat_map(|h| [h.start, h.length, h.kind as u32])
            .collect()
    });
    *count = runs.len();
    Box::into_raw(runs).cast()
}

/// # Safety
/// `runs` is null (nothing to free) or, with `count`, came from one
/// `tl_source_highlights`, freed once.
#[no_mangle]
pub unsafe extern "C" fn tl_source_free_runs(runs: *mut u32, count: usize) {
    if !runs.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            runs, count,
        )));
    }
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
    more: bool,
}

/// The editing commands, as `texlocal_syntax::SourceDocument` has them:
/// "completions", "toggle_comment", "indent", "set_heading", "insert_block",
/// "insert_symbol", "math_at", "text_styles", "not_prose" (the
/// `selection`'s) and "text". Returns the result's JSON (free it with
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
    let call = |doc: &mut SourceDocument| {
        let a: SourceArgs = serde_json::from_str(str_arg(args_json)?).ok()?;
        Some(match str_arg(command)? {
            "completions" => {
                json_string(doc.completions(a.caret, a.explicit, &a.labels, &a.citations))
            }
            "toggle_comment" => json_string(doc.toggle_comment(&a.selections)),
            "indent" => json_string(doc.indent(&a.selections, a.more)),
            "set_heading" => json_string(doc.set_heading(a.caret, &a.command)),
            "insert_block" => json_string(doc.insert_block(&a.id, a.selection)),
            "insert_symbol" => json_string(doc.insert_symbol(&a.command, a.selection)),
            "math_at" => json_string(doc.math_at(a.caret)),
            "text_styles" => json_string(doc.text_styles(a.selection)),
            "not_prose" => json_string(doc.not_prose(a.selection.start, a.selection.length)),
            "text" => json_string(doc.text()),
            _ => return None,
        })
    };
    on_source(source, None, call).unwrap_or(std::ptr::null_mut())
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
