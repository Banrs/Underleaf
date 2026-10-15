//! The C ABI the macOS app links: one JSON-in, JSON-out call over
//! `texlocal_core::service`, the same command names and arguments the browser
//! server uses. See `include/texlocal.h`.
//!
//! `tl_call` blocks until the command finishes (a compile can take minutes),
//! so hosts call it off their UI thread, or use `tl_call_async`. Concurrent
//! calls from several threads are fine: each drives the handle's runtime on
//! its own thread. `session_*` commands go to `texlocal_core::session`, whose
//! events reach the listener `tl_set_listener` sets.
//!
//! `tl_source_*` are the editor's: `texlocal_syntax`'s view of a file's text,
//! answering in UTF-16 offsets, on the editor's thread. A source from
//! `tl_session_source` is a session's document: its edits are saved and
//! previewed from there too.

use std::borrow::Cow;
use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use texlocal_core::events::{Hub, Listener};
use texlocal_core::service::{Service, arg, string_arg};
use texlocal_core::session::{Document, Sessions};
use texlocal_core::{CoreError, import, zipexport};
use texlocal_syntax::{SourceDocument, TextRange};

pub struct TlHandle {
    runtime: tokio::runtime::Runtime,
    host: Arc<Host>,
}

struct Host {
    runtime: tokio::runtime::Handle,
    service: Arc<Service>,
    sessions: Sessions,
}

impl Host {
    /// Absolute-path commands belong to the in-process host. Only the shared
    /// commands are forwarded to `Service::call`, which the browser exposes.
    fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        if let Some(answer) = self.runtime.block_on(self.sessions.call(command, args)) {
            return answer;
        }
        let service = &self.service;
        let s = |key: &str| string_arg(args, key);
        let path = |p: PathBuf| json!(p.to_string_lossy());
        match command {
            "pdf_path" => service.pdf_path(s("id")?).map(path),
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
                service.kill_all();
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

/// A C function and the pointer the host passes back to it.
#[derive(Clone, Copy)]
struct Callback {
    call: extern "C" fn(*mut c_void, *const c_char),
    ctx: *mut c_void,
}

// SAFETY: the header asks the host for a callback any thread may call with its pointer.
unsafe impl Send for Callback {}
unsafe impl Sync for Callback {}

impl Callback {
    fn send(self, value: &Value) {
        let text = CString::new(value.to_string()).expect("JSON has no interior NUL");
        (self.call)(self.ctx, text.as_ptr());
    }
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
    body: impl FnOnce(&mut TlSource) -> T,
) -> T {
    match unsafe { source.cast_mut().as_mut() } {
        Some(source) => caught(|| body(source)).unwrap_or(none),
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
    (!ptr.is_null()).then(|| unsafe { CStr::from_ptr(ptr) }.to_str().ok())?
}

/// Open the service over the library folder `data_dir`, which the host
/// chooses (the Mac app by `default_data_dir`'s rule, in Swift). Returns null
/// if `data_dir` is null or not UTF-8, the directory cannot be created or the
/// runtime cannot start.
///
/// # Safety
/// `data_dir` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_open(data_dir: *const c_char) -> *mut TlHandle {
    let Some(dir) = unsafe { str_arg(data_dir) }.map(PathBuf::from) else {
        return std::ptr::null_mut();
    };
    caught(|| {
        std::fs::create_dir_all(&dir).ok()?;
        let runtime = tokio::runtime::Runtime::new().ok()?;
        let service = Arc::new(Service::new(dir));
        let sessions = Sessions::new(Arc::clone(&service), Arc::new(Hub::default()));
        let host = Arc::new(Host {
            runtime: runtime.handle().clone(),
            service,
            sessions,
        });
        Some(Box::new(TlHandle { runtime, host }))
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_call(
    handle: *const TlHandle,
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let result = caught(|| {
        let handle =
            unsafe { handle.as_ref() }.ok_or_else(|| CoreError::bad_request("No handle"))?;
        let (command, args) = unsafe { command_args(command, args_json) }?;
        handle.host.call(command, &args)
    })
    .unwrap_or_else(|| Err(CoreError::internal("The command panicked")));
    json_string(envelope(result))
}

/// # Safety
/// The strings are null or NUL-terminated.
unsafe fn command_args<'a>(
    command: *const c_char,
    args_json: *const c_char,
) -> Result<(&'a str, Value), CoreError> {
    let command =
        unsafe { str_arg(command) }.ok_or_else(|| CoreError::bad_request("Invalid command"))?;
    let args: Value = match unsafe { str_arg(args_json) } {
        Some(text) => serde_json::from_str(text)
            .map_err(|e| CoreError::bad_request(format!("Invalid JSON: {e}")))?,
        None if args_json.is_null() => json!({}),
        None => return Err(CoreError::bad_request("Arguments are not UTF-8")),
    };
    Ok((command, args))
}

fn envelope(result: Result<Value, CoreError>) -> Value {
    match result {
        // Moved into its envelope: `json!` would copy the whole result first.
        Ok(value) => Value::Object(Map::from_iter([("ok".to_owned(), value)])),
        Err(err) => json!({ "error": err.message, "status": err.status }),
    }
}

/// `tl_call` without waiting: the command runs on a core thread, which then
/// calls `done` with the envelope `tl_call` would answer, valid only during
/// the call. A null `done` runs the command for its effect alone.
///
/// # Safety
/// As `tl_call`; `done`, if not null, may be called from any thread with
/// `ctx`, until the handle is closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_call_async(
    handle: *const TlHandle,
    command: *const c_char,
    args_json: *const c_char,
    done: Option<extern "C" fn(*mut c_void, *const c_char)>,
    ctx: *mut c_void,
) {
    let done = done.map(|call| Callback { call, ctx });
    let reply = move |result| {
        if let Some(done) = done {
            let _ = caught(|| done.send(&envelope(result)));
        }
    };
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return reply(Err(CoreError::bad_request("No handle")));
    };
    let parsed = unsafe { command_args(command, args_json) };
    let parsed = parsed.map(|(command, args)| (command.to_owned(), args));
    let host = Arc::clone(&handle.host);
    handle.runtime.spawn_blocking(move || {
        let result = parsed.and_then(|(command, args)| {
            caught(|| host.call(&command, &args))
                .unwrap_or_else(|| Err(CoreError::internal("The command panicked")))
        });
        reply(result);
    });
}

/// Sets the function the core's events go to, one JSON object at a time
/// (`{"type": …, "session": …, …}`), in order, on a thread of the core's
/// own; null removes it. Returns once no call to the previous one is running.
///
/// # Safety
/// `handle` came from `tl_open` and is not closed; `listener`, if not null,
/// may be called from that thread with `ctx` until it is replaced or the
/// handle closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_set_listener(
    handle: *const TlHandle,
    listener: Option<extern "C" fn(*mut c_void, *const c_char)>,
    ctx: *mut c_void,
) {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    let listener = listener.map(|call| {
        let callback = Callback { call, ctx };
        Box::new(move |event: &Value| callback.send(event)) as Listener
    });
    caught(|| handle.host.sessions.hub().set_listener(listener));
}

/// Free a string `tl_call` returned. Null is ignored.
///
/// # Safety
/// `text` came from `tl_call` and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

/// Stop every running compile and live preview and release the handle. Null
/// is ignored.
///
/// # Safety
/// `handle` came from `tl_open`, no call on it is in flight, and it is closed
/// once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_close(handle: *mut TlHandle) {
    if handle.is_null() {
        return;
    }
    let handle = unsafe { Box::from_raw(handle) };
    // Dropping the runtime and the service is guarded too.
    caught(move || {
        let host = &handle.host;
        host.runtime.block_on(host.sessions.close_all());
        host.sessions.hub().set_listener(None);
        host.service.kill_all();
        drop(handle);
    });
}

/// The document session `session` has open at `path` (`session_open_document`),
/// as a source the editor edits and highlights: each edit is the session's
/// too. Null if the session hasn't it open. Free it with `tl_source_free`,
/// which leaves the document open.
///
/// # Safety
/// `handle` came from `tl_open` and is not closed; `path` is null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_session_source(
    handle: *const TlHandle,
    session: u64,
    path: *const c_char,
) -> *mut TlSource {
    let (Some(handle), Some(path)) = (unsafe { handle.as_ref() }, unsafe { str_arg(path) }) else {
        return std::ptr::null_mut();
    };
    caught(|| handle.host.sessions.document(session, path))
        .flatten()
        .map_or(std::ptr::null_mut(), |document| {
            Box::into_raw(Box::new(TlSource(Source::Session(document))))
        })
}

/// A file's text as the editor has it (`texlocal_syntax::SourceDocument`),
/// with the project's labels and citations, which its completions offer in
/// `\ref{` and `\cite{`.
pub struct TlSource(Source);

enum Source {
    /// The host's own: it sets the symbols when they change, rather than
    /// sending them with every key's completions, a thesis's bibliography
    /// being thousands of keys.
    Own {
        doc: SourceDocument,
        labels: Vec<String>,
        citations: Vec<String>,
    },
    /// A session's document, with the symbols the session scanned.
    Session(Document),
}

impl TlSource {
    fn with<T>(&mut self, body: impl FnOnce(&mut SourceDocument, &[String], &[String]) -> T) -> T {
        match &mut self.0 {
            Source::Own {
                doc,
                labels,
                citations,
            } => body(doc, labels, citations),
            Source::Session(document) => {
                let symbols = document.symbols();
                document.with(|doc| body(doc, &symbols.labels, &symbols.citations))
            }
        }
    }
}

/// UTF-8 text by its byte count, so a U+0000 in the editor's text reaches
/// the mirror. Bytes that aren't UTF-8 read as U+FFFD, as Swift decodes
/// them, so an edit still lands with the length the editor has.
unsafe fn text_arg<'a>(ptr: *const u8, len: usize) -> Cow<'a, str> {
    if ptr.is_null() {
        return Cow::Borrowed("");
    }
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// Never null: reading the text into lines can't fail.
///
/// # Safety
/// `text` is null (empty) or `len` bytes of UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_new(text: *const u8, len: usize) -> *mut TlSource {
    Box::into_raw(Box::new(TlSource(Source::Own {
        doc: SourceDocument::new(&unsafe { text_arg(text, len) }),
        labels: Vec::new(),
        citations: Vec::new(),
    })))
}

/// The editor replaced `length` units at `start` with `text`. Each call on
/// a source answers as for a null source if it fails: nothing, 0, no runs.
///
/// # Safety
/// `source` came from `tl_source_new` and is not freed, and no other call
/// on it (`const` queries included) overlaps this one; `text` is null
/// (nothing) or `len` bytes of UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_edit(
    source: *mut TlSource,
    start: u32,
    length: u32,
    text: *const u8,
    len: usize,
) {
    let text = unsafe { text_arg(text, len) };
    unsafe {
        on_source(source, (), |source| match &mut source.0 {
            Source::Own { doc, .. } => doc.edit(start, length, &text),
            Source::Session(document) => document.edit(start, length, &text),
        })
    }
}

/// The editor now shows `text` whole, as a `document_reload` event gave it:
/// for a session's document, its text from disk, not an edit to save.
///
/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_reload(source: *mut TlSource, text: *const u8, len: usize) {
    let text = unsafe { text_arg(text, len) };
    unsafe {
        on_source(source, (), |source| match &mut source.0 {
            Source::Own { doc, .. } => *doc = SourceDocument::new(&text),
            Source::Session(document) => document.reload(&text),
        })
    }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_at(source: *const TlSource, offset: u32) -> u32 {
    unsafe {
        on_source(source, 0, |source| {
            source.with(|doc, _, _| doc.line_at(offset))
        })
    }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_start(source: *const TlSource, line: u32) -> u32 {
    unsafe {
        on_source(source, 0, |source| {
            source.with(|doc, _, _| doc.line_start(line))
        })
    }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_count(source: *const TlSource) -> u32 {
    unsafe {
        on_source(source, 0, |source| {
            source.with(|doc, _, _| doc.line_count())
        })
    }
}

/// The highlighted runs of the lines a range touches, as start, length and
/// kind (`HighlightKind`'s order) for each; `count` is the number of values.
/// Free them with `tl_source_free_runs`. A null `count` gets null, as runs
/// could not be freed without their count.
///
/// # Safety
/// As `tl_source_edit`; `count` is null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_highlights(
    source: *mut TlSource,
    start: u32,
    length: u32,
    count: *mut usize,
) -> *mut u32 {
    let Some(count) = (unsafe { count.as_mut() }) else {
        return std::ptr::null_mut();
    };
    let runs: Box<[u32]> = unsafe {
        on_source(source, Box::default(), |source| {
            let runs = source.with(|doc, _, _| doc.highlights(start, length));
            let runs = runs.into_iter();
            runs.flat_map(|h| [h.start, h.length, h.kind as u32])
                .collect()
        })
    };
    *count = runs.len();
    Box::into_raw(runs).cast()
}

/// # Safety
/// `runs` is null (nothing to free) or, with `count`, came from one
/// `tl_source_highlights`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free_runs(runs: *mut u32, count: usize) {
    if !runs.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(runs, count)) });
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
/// `selection`'s) and "text"; and "set_symbols", whose `labels` and
/// `citations` "completions" offers until they are set again (it answers
/// null). Returns the result's JSON (free it with `tl_free`), or null for an
/// unknown command or arguments.
///
/// # Safety
/// As `tl_source_edit`; the strings are null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_call(
    source: *const TlSource,
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let call = |source: &mut TlSource| {
        let a: SourceArgs = serde_json::from_str(unsafe { str_arg(args_json) }?).ok()?;
        let command = unsafe { str_arg(command) }?;
        if command == "set_symbols" {
            // A session's document has the symbols its session scans.
            if let Source::Own {
                labels, citations, ..
            } = &mut source.0
            {
                (*labels, *citations) = (a.labels, a.citations);
            }
            return Some(json_string(()));
        }
        source.with(|doc, labels, citations| answer(doc, command, a, labels, citations))
    };
    unsafe { on_source(source, None, call) }.unwrap_or(std::ptr::null_mut())
}

fn answer(
    doc: &mut SourceDocument,
    command: &str,
    a: SourceArgs,
    labels: &[String],
    citations: &[String],
) -> Option<*mut c_char> {
    Some(match command {
        "completions" => json_string(doc.completions(a.caret, a.explicit, labels, citations)),
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
}

/// Null is ignored.
///
/// # Safety
/// `source` came from `tl_source_new` and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free(source: *mut TlSource) {
    if !source.is_null() {
        drop(unsafe { Box::from_raw(source) });
    }
}
