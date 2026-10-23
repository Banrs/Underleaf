//! The C ABI the Mac app links and the Windows app loads; `include/texlocal.h` is its
//! contract.

use std::borrow::Cow;
use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use texlocal_core::CoreError;
use texlocal_core::events::Listener;
use texlocal_core::service::Service;
use texlocal_core::session::{Document, Sessions};
use texlocal_core::syntax::{self, SourceDocument, TextRange};

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
    fn call(&self, command: &str, args: &Value) -> Result<Value, CoreError> {
        if command.starts_with("session_") {
            self.runtime.block_on(self.sessions.call(command, args))
        } else {
            self.runtime.block_on(self.service.call(command, args))
        }
    }
}

/// `body`'s result, or none if it panicked: no panic may unwind into the
/// host, which would abort the app and lose the user's unsaved text.
fn caught<T>(body: impl FnOnce() -> T) -> Option<T> {
    catch_unwind(AssertUnwindSafe(body)).ok()
}

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
        (self.call)(self.ctx, c_json(value.to_string()).as_ptr());
    }
}

/// JSON text for C: JSON escapes a NUL inside a string, so it holds none.
fn c_json(text: String) -> CString {
    CString::new(text).expect("JSON has no interior NUL")
}

/// # Safety
/// `ptr` is null or a NUL-terminated string valid for the call.
unsafe fn str_arg<'a>(ptr: *const c_char) -> Option<&'a str> {
    (!ptr.is_null()).then(|| unsafe { CStr::from_ptr(ptr) }.to_str().ok())?
}

/// # Safety
/// `engine` points to a `tl_engine` whose functions are the in-process engine's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_set_engine(engine: *const texlocal_core::inprocess::Engine) {
    texlocal_core::inprocess::set_engine(unsafe { *engine });
}

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
        let sessions = Sessions::new(Arc::clone(&service));
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

/// # Safety
/// `handle` came from `tl_open` and is not closed; the strings are null or
/// NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_call(
    handle: *const TlHandle,
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let answer = caught(|| {
        let handle =
            unsafe { handle.as_ref() }.ok_or_else(|| CoreError::bad_request("No handle"))?;
        let (command, args) = unsafe { command_args(command, args_json) }?;
        handle.host.call(command, &args)
    });
    c_json(envelope(answer.unwrap_or_else(|| Err(panicked()))).to_string()).into_raw()
}

fn panicked() -> CoreError {
    CoreError::internal("The command panicked")
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
        Ok(value) => json!({ "ok": value }),
        Err(err) => json!({ "error": err.message, "status": err.status }),
    }
}

/// A host's `done` for one call, called once: with the answer, or, dropped unanswered, with
/// the command's panic or the close that came first.
struct Done(Option<Callback>);

impl Done {
    fn send(mut self, result: Result<Value, CoreError>) {
        if let Some(done) = self.0.take() {
            done.send(&envelope(result));
        }
    }
}

impl Drop for Done {
    fn drop(&mut self) {
        if let Some(done) = self.0.take() {
            let unanswered = if std::thread::panicking() {
                panicked()
            } else {
                CoreError::internal("TeXLocal closed before it answered.")
            };
            done.send(&envelope(Err(unanswered)));
        }
    }
}

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
    let done = Done(done.map(|call| Callback { call, ctx }));
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return done.send(Err(CoreError::bad_request("No handle")));
    };
    let (command, args) = match unsafe { command_args(command, args_json) } {
        Ok(parsed) => parsed,
        Err(err) => return done.send(Err(err)),
    };
    // `done` is called on the blocking pool, where it may call the core again, and which a
    // close waits for once the sessions have answered.
    if command.starts_with("session_") && command != "session_open" {
        let Some(answer) = caught(|| handle.host.sessions.send(command, &args)) else {
            return done.send(Err(panicked()));
        };
        let runtime = handle.host.runtime.clone();
        handle
            .runtime
            .spawn_blocking(move || done.send(runtime.block_on(answer)));
    } else {
        let (host, command) = (Arc::clone(&handle.host), command.to_owned());
        handle
            .runtime
            .spawn_blocking(move || done.send(host.call(&command, &args)));
    }
}

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
    caught(|| handle.host.sessions.set_listener(listener));
}

/// # Safety
/// `text` is null or a string this library answered, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

/// # Safety
/// `handle` is null or came from `tl_open`, with no call on it in flight, and is
/// closed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_close(handle: *mut TlHandle) {
    if handle.is_null() {
        return;
    }
    let handle = unsafe { Box::from_raw(handle) };
    caught(move || {
        let host = &handle.host;
        host.runtime.block_on(host.sessions.close_all());
        host.sessions.set_listener(None);
        host.service.kill_all();
        drop(handle);
    });
}

/// A file's text as the editor has it (`syntax::SourceDocument`):
/// the host's own, or a session's document.
pub enum TlSource {
    Own(Box<SourceDocument>),
    Session(Document),
}

impl TlSource {
    fn with<T>(&mut self, body: impl FnOnce(&mut SourceDocument) -> T) -> T {
        match self {
            Self::Own(doc) => body(doc),
            Self::Session(document) => document.with(body),
        }
    }
}

/// `body`'s answer for `source`, or the default for a null source or a panic.
///
/// # Safety
/// `source` is null or came from `tl_source_new` and is not freed, and no
/// two calls on it overlap: one thread at a time, queries included.
unsafe fn on_source<T: Default>(source: *mut TlSource, body: impl FnOnce(&mut TlSource) -> T) -> T {
    unsafe { source.as_mut() }
        .and_then(|source| caught(|| body(source)))
        .unwrap_or_default()
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
            document.reset_typing();
            Box::into_raw(Box::new(TlSource::Session(document)))
        })
}

/// # Safety
/// `text` is null (empty) or `len` bytes of UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_new(text: *const u8, len: usize) -> *mut TlSource {
    let doc = SourceDocument::new(&unsafe { text_arg(text, len) });
    Box::into_raw(Box::new(TlSource::Own(Box::new(doc))))
}

/// # Safety
/// `source` came from `tl_source_new` and is not freed, and no other call
/// on it (queries included) overlaps this one; `text` is null (nothing) or
/// `len` bytes of UTF-8; `changing` is null or valid for a read.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_edit(
    source: *mut TlSource,
    start: u32,
    length: u32,
    text: *const u8,
    len: usize,
    changing: *const TextRange,
    mirroring: bool,
) -> *mut c_char {
    let text = unsafe { text_arg(text, len) };
    let changing = unsafe { changing.as_ref() }.copied();
    let followed = |source: &mut TlSource| {
        match source {
            TlSource::Own(doc) => doc.edit(start, length, &text),
            TlSource::Session(document) => document.edit(start, length, &text),
        }
        let delta = text.encode_utf16().count() as i64 - length as i64;
        source.with(|doc| {
            doc.follow(TextRange { start, length }, delta, changing, mirroring);
            let mirror = (!mirroring).then(|| doc.mirror_snippet());
            let mirror = mirror.filter(|edits| !edits.is_empty());
            mirror.map(|edits| c_json(json!(edits).to_string()).into_raw())
        })
    };
    unsafe { on_source(source, followed) }.unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_select(
    source: *mut TlSource,
    start: u32,
    length: u32,
    mirroring: bool,
) {
    let selection = TextRange { start, length };
    unsafe { on_source(source, |s| s.with(|doc| doc.select(selection, mirroring))) }
}

/// # Safety
/// As `tl_source_edit`; `len` is null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_text(source: *mut TlSource, len: *mut usize) -> *mut u8 {
    let Some(len) = (unsafe { len.as_mut() }) else {
        return std::ptr::null_mut();
    };
    let text = unsafe { on_source(source, |s| s.with(|doc| doc.text())) };
    let bytes = text.into_bytes().into_boxed_slice();
    *len = bytes.len();
    Box::into_raw(bytes).cast()
}

/// # Safety
/// `text` is null (nothing to free) or, with `len`, came from one
/// `tl_source_text`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free_text(text: *mut u8, len: usize) {
    if !text.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(text, len)) });
    }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_reload(
    source: *mut TlSource,
    text: *const u8,
    len: usize,
) -> bool {
    let text = unsafe { text_arg(text, len) };
    let reload = |source: &mut TlSource| match source {
        TlSource::Own(doc) => {
            **doc = SourceDocument::new(&text);
            true
        }
        TlSource::Session(document) => document.reload(&text),
    };
    unsafe { on_source(source, reload) }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_at(source: *mut TlSource, offset: u32) -> u32 {
    unsafe { on_source(source, |s| s.with(|doc| doc.line_at(offset))) }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_start(source: *mut TlSource, line: u32) -> u32 {
    unsafe { on_source(source, |s| s.with(|doc| doc.line_start(line))) }
}

/// # Safety
/// As `tl_source_edit`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_count(source: *mut TlSource) -> u32 {
    unsafe { on_source(source, |s| s.with(|doc| doc.line_count())) }
}

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
    let highlights = |source: &mut TlSource| {
        let runs = source.with(|doc| doc.highlights(start, length));
        runs.into_iter()
            .flat_map(|h| [h.start, h.length, h.kind as u32])
            .collect()
    };
    let runs: Box<[u32]> = unsafe { on_source(source, highlights) };
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

/// # Safety
/// As `tl_source_edit`; the strings are null or NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_call(
    source: *mut TlSource,
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let call = |source: &mut TlSource| {
        let (command, args) = unsafe { (str_arg(command)?, str_arg(args_json)?) };
        match source {
            // The session counts a document's edits, not the syntax module.
            TlSource::Session(document) if command == "version" => {
                Some(document.version().to_string())
            }
            _ => source.with(|doc| doc.call(command, args)),
        }
    };
    let answer = unsafe { on_source(source, call) };
    answer.map_or(std::ptr::null_mut(), |json| c_json(json).into_raw())
}

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
        .map_or(std::ptr::null_mut(), |json| c_json(json).into_raw())
}

/// # Safety
/// `source` is null or came from `tl_source_new`, and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free(source: *mut TlSource) {
    if !source.is_null() {
        drop(unsafe { Box::from_raw(source) });
    }
}

#[cfg(test)]
mod tests;
