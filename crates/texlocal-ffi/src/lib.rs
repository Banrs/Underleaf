//! The C ABI the Mac app links and the Windows app loads: one JSON-in,
//! JSON-out call over `texlocal_core::service`. See `include/texlocal.h`.
//!
//! `tl_call` blocks until the command finishes (a compile can take minutes),
//! so hosts call it off their UI thread, or use `tl_call_async`. Concurrent
//! calls from several threads are fine: each drives the handle's runtime on
//! its own thread. `session_*` commands go to `texlocal_core::session`, whose
//! events reach the listener `tl_set_listener` sets.
//!
//! `tl_source_*` are the editor's: `texlocal_core::syntax`'s view of a file's text,
//! answering in UTF-16 offsets, on the editor's thread. A source from
//! `tl_session_source` is a session's document: its edits are saved and
//! previewed from there too.

use std::borrow::Cow;
use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::Serialize;
use serde_json::{Map, Value, json};
use texlocal_core::events::{Hub, Listener};
use texlocal_core::service::{Service, arg, string_arg};
use texlocal_core::session::{Document, Sessions};
use texlocal_core::syntax::{self, SourceDocument};
use texlocal_core::{CoreError, import, zipexport};

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
    /// `call`, the answer handed to `deliver`, which makes the host's copy of it. A new
    /// session's events are held until `deliver` returns, so none comes before the answer.
    fn call_then<T, F>(&self, command: &str, args: &Value, deliver: F) -> T
    where
        F: FnOnce(Result<Value, CoreError>) -> T,
    {
        match self
            .runtime
            .block_on(self.sessions.call_then(command, args, deliver))
        {
            Ok(delivered) => delivered,
            Err(deliver) => deliver(self.call(command, args)),
        }
    }

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
/// chooses: both apps take `TEXLOCAL_DATA` when set, else ~/TeXLocal, which
/// is visible in the file manager, syncable, and (unlike ~/Documents on
/// macOS) not behind a privacy gate, so no host hangs waiting on a
/// folder-permission prompt. Returns null if `data_dir` is null or not UTF-8,
/// the directory cannot be created or the runtime cannot start.
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
    let made = caught(|| {
        let handle =
            unsafe { handle.as_ref() }.ok_or_else(|| CoreError::bad_request("No handle"))?;
        let (command, args) = unsafe { command_args(command, args_json) }?;
        // The envelope is made inside the call: a new session's events wait for it.
        Ok(handle
            .host
            .call_then(command, &args, |result| json_string(envelope(result))))
    })
    .unwrap_or_else(|| Err(CoreError::internal("The command panicked")));
    made.unwrap_or_else(|err| json_string(envelope(Err(err))))
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
        // `done` is called inside the call: a new session's events wait for it to return.
        let answered = caught(|| match &parsed {
            Ok((command, args)) => host.call_then(command, args, reply),
            Err(err) => reply(Err(err.clone())),
        });
        if answered.is_none() {
            reply(Err(CoreError::internal("The command panicked")));
        }
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
/// which leaves the document open. The document's typing state (the brackets
/// closed for the user, a snippet's fields) starts empty for each source
/// handed out, so one shown again keeps nothing from an earlier visit.
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
            // A visit's closers and snippet are over with it.
            document.reset_typing();
            Box::into_raw(Box::new(TlSource(Source::Session(document))))
        })
}

/// A file's text as the editor has it (`syntax::SourceDocument`):
/// the host's own, or a session's document.
pub struct TlSource(Source);

enum Source {
    Own(Box<SourceDocument>),
    Session(Document),
}

impl TlSource {
    fn with<T>(&mut self, body: impl FnOnce(&mut SourceDocument) -> T) -> T {
        match &mut self.0 {
            Source::Own(doc) => body(doc),
            Source::Session(document) => document.with(body),
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
    Box::into_raw(Box::new(TlSource(Source::Own(Box::new(
        SourceDocument::new(&unsafe { text_arg(text, len) }),
    )))))
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
            Source::Own(doc) => doc.edit(start, length, &text),
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
            Source::Own(doc) => **doc = SourceDocument::new(&text),
            Source::Session(document) => document.reload(&text),
        })
    }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_at(source: *const TlSource, offset: u32) -> u32 {
    unsafe { on_source(source, 0, |source| source.with(|doc| doc.line_at(offset))) }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_start(source: *const TlSource, line: u32) -> u32 {
    unsafe { on_source(source, 0, |source| source.with(|doc| doc.line_start(line))) }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_count(source: *const TlSource) -> u32 {
    unsafe { on_source(source, 0, |source| source.with(|doc| doc.line_count())) }
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
            let runs = source.with(|doc| doc.highlights(start, length));
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

/// `syntax::SourceDocument::call`'s commands, and `syntax::call`'s. Returns the result's JSON (free it with
/// `tl_free`), or null for an unknown command or arguments.
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
        let (command, args) = unsafe { (str_arg(command)?, str_arg(args_json)?) };
        source.with(|doc| doc.call(command, args))
    };
    let answer = unsafe { on_source(source, None, call) };
    answer.map_or(std::ptr::null_mut(), owned_string)
}

/// JSON never holds a NUL: it escapes one inside a string.
fn owned_string(text: String) -> *mut c_char {
    CString::new(text).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// `syntax::call`'s commands, which need no source: the themes,
/// the menus' catalogue, a class's headings, and maths and symbols as SVG
/// ("math_svg", "glyph_svg"). Any thread. Returns the result's JSON (free it
/// with `tl_free`), or null for an unknown command or arguments.
///
/// # Safety
/// The strings are null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_syntax_call(
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let call = || {
        let (command, args) = unsafe { (str_arg(command)?, str_arg(args_json)?) };
        syntax::call(command, args)
    };
    caught(call)
        .flatten()
        .map_or(std::ptr::null_mut(), owned_string)
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
