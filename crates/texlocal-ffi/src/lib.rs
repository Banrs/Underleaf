//! The C ABI the Mac app links and the Windows app loads, over
//! `texlocal_core`'s service, sessions and syntax. `include/texlocal.h` is its
//! contract and documents each function.
//!
//! # Safety
//! Each function takes what the header says it does: a handle from `tl_open`
//! not yet closed, a source from `tl_source_new` or `tl_session_source` not
//! yet freed and used by one thread at a time, NUL-terminated strings, texts
//! of `len` bytes, and each answer freed once by its own free function.
//! Pointers the header marks `_Nullable` may be null.
//!
//! No panic may unwind into the host, which would abort the app and lose the
//! user's unsaved text: each entry point that could panic catches it and
//! answers as it would for a null argument, or with an error envelope.

use std::borrow::Cow;
use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr::{null_mut, slice_from_raw_parts_mut};
use std::sync::Arc;

use serde_json::{Map, Value, json};
use texlocal_core::CoreError;
use texlocal_core::events::Listener;
use texlocal_core::service::Service;
use texlocal_core::session::{Document, Sessions};
use texlocal_core::syntax::{self, SourceDocument, TextRange};
use tokio::runtime::{Handle, Runtime};

type Str = *const c_char;
type Bytes = *const u8;
type Source = *mut TlSource;
type TlCallback = extern "C" fn(*mut c_void, Str);
type Answer = Result<Value, CoreError>;

pub struct TlHandle {
    runtime: Runtime,
    host: Arc<Host>,
}

struct Host {
    service: Arc<Service>,
    sessions: Sessions,
}

impl Host {
    async fn call(&self, command: &str, args: &Value) -> Answer {
        if command.starts_with("session_") {
            self.sessions.call(command, args).await
        } else {
            self.service.call(command, args).await
        }
    }
}

fn caught<T>(body: impl FnOnce() -> T) -> Option<T> {
    catch_unwind(AssertUnwindSafe(body)).ok()
}

fn panicked() -> CoreError {
    CoreError::internal("The command panicked")
}

unsafe fn str_arg<'a>(ptr: Str) -> Option<&'a str> {
    (!ptr.is_null()).then(|| unsafe { CStr::from_ptr(ptr) }.to_str().ok())?
}

/// UTF-8 by its byte count, so a U+0000 in the editor's text is text. Bytes
/// that aren't UTF-8 read as U+FFFD, as Swift decodes them, so an edit still
/// lands with the length the editor has.
unsafe fn text_arg<'a>(ptr: Bytes, len: usize) -> Cow<'a, str> {
    if ptr.is_null() {
        return Cow::Borrowed("");
    }
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// JSON escapes a NUL inside a string, so its text holds none.
fn json_text(value: &Value) -> CString {
    CString::new(value.to_string()).expect("JSON holds no NUL")
}

fn string_out(text: Option<String>) -> *mut c_char {
    let text = text.and_then(|text| CString::new(text).ok());
    text.map_or(null_mut(), CString::into_raw)
}

/// Items for a free function that takes their count with them.
fn slice_out<T>(items: Vec<T>, count: &mut usize) -> *mut T {
    *count = items.len();
    Box::into_raw(items.into_boxed_slice()).cast()
}

unsafe fn free_slice<T>(items: *mut T, count: usize) {
    if !items.is_null() {
        drop(unsafe { Box::from_raw(slice_from_raw_parts_mut(items, count)) });
    }
}

fn envelope(answer: Answer) -> CString {
    json_text(&match answer {
        // Moved into its envelope: `json!` would copy the whole result first.
        Ok(value) => Value::Object(Map::from_iter([("ok".to_owned(), value)])),
        Err(err) => json!({ "error": err.message, "status": err.status }),
    })
}

/// A call's handle, command and arguments (null for `{}`).
unsafe fn request<'a>(
    handle: *const TlHandle,
    command: Str,
    args: Str,
) -> Result<(&'a TlHandle, &'a str, Value), CoreError> {
    let bad = |why: &str| CoreError::bad_request(why);
    let handle = unsafe { handle.as_ref() }.ok_or_else(|| bad("No handle"))?;
    let command = unsafe { str_arg(command) }.ok_or_else(|| bad("Invalid command"))?;
    let args = match unsafe { str_arg(args) } {
        _ if args.is_null() => json!({}),
        Some(args) => serde_json::from_str(args).map_err(|e| bad(&format!("Invalid JSON: {e}")))?,
        None => return Err(bad("Arguments are not UTF-8")),
    };
    Ok((handle, command, args))
}

/// A host's function and the pointer it is called with.
#[derive(Clone, Copy)]
struct Callback(TlCallback, *mut c_void);

// SAFETY: the header asks the host for a callback any thread may call with its pointer.
unsafe impl Send for Callback {}
unsafe impl Sync for Callback {}

impl Callback {
    fn send(self, json: &CStr) {
        (self.0)(self.1, json.as_ptr());
    }
}

/// A `tl_call_async`'s `done`, called once: with the answer, or, should the
/// command panic first, with that error as this is dropped.
struct Done(Option<Callback>);

impl Done {
    fn send(mut self, answer: Answer) {
        self.answer(answer);
    }

    fn answer(&mut self, answer: Answer) {
        if let Some(done) = self.0.take() {
            done.send(&envelope(answer));
        }
    }
}

impl Drop for Done {
    fn drop(&mut self) {
        self.answer(Err(panicked()));
    }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_open(data_dir: Str) -> *mut TlHandle {
    let Some(dir) = (unsafe { str_arg(data_dir) }) else {
        return null_mut();
    };
    let open = || {
        std::fs::create_dir_all(dir).ok()?;
        let runtime = Runtime::new().ok()?;
        let service = Arc::new(Service::new(dir.into()));
        let sessions = Sessions::new(Arc::clone(&service));
        let host = Arc::new(Host { service, sessions });
        Some(Box::new(TlHandle { runtime, host }))
    };
    caught(open).flatten().map_or(null_mut(), Box::into_raw)
}

/// Waits on the caller's thread, which drives the runtime meanwhile, so
/// several threads may call at once.
///
/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_call(handle: *const TlHandle, command: Str, args: Str) -> *mut c_char {
    let answer = caught(|| {
        let (handle, command, args) = unsafe { request(handle, command, args) }?;
        handle.runtime.block_on(handle.host.call(command, &args))
    });
    envelope(answer.unwrap_or_else(|| Err(panicked()))).into_raw()
}

/// A session's commands are queued for it before this returns
/// (`Sessions::send`), so it takes them in the order they were sent. Any
/// other command keeps a thread of its own busy, as the service's work does.
///
/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_call_async(
    handle: *const TlHandle,
    command: Str,
    args: Str,
    done: Option<TlCallback>,
    ctx: *mut c_void,
) {
    let done = Done(done.map(|done| Callback(done, ctx)));
    let (handle, command, args) = match unsafe { request(handle, command, args) } {
        Ok(request) => request,
        Err(err) => return done.send(Err(err)),
    };
    if command.starts_with("session_") && command != "session_open" {
        // Should queueing panic, `done` is dropped and answers so.
        if let Some(answer) = caught(|| handle.host.sessions.send(command, &args)) {
            handle.runtime.spawn(async move { done.send(answer.await) });
        }
    } else {
        let (host, command) = (Arc::clone(&handle.host), command.to_owned());
        handle.runtime.spawn_blocking(move || {
            done.send(Handle::current().block_on(host.call(&command, &args)));
        });
    }
}

/// The hub holds a read lock through each call to the listener, so replacing
/// it waits out the call running.
///
/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_set_listener(
    handle: *const TlHandle,
    listener: Option<TlCallback>,
    ctx: *mut c_void,
) {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    let listener = listener.map(|listener| {
        let callback = Callback(listener, ctx);
        Box::new(move |event: &Value| callback.send(&json_text(event))) as Listener
    });
    caught(|| handle.host.sessions.set_listener(listener));
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_close(handle: *mut TlHandle) {
    if handle.is_null() {
        return;
    }
    let handle = unsafe { Box::from_raw(handle) };
    // Dropping the runtime and the service is guarded too.
    caught(move || {
        let host = &handle.host;
        handle.runtime.block_on(host.sessions.close_all());
        host.sessions.set_listener(None);
        host.service.kill_all();
        drop(handle);
    });
}

/// A file's text as the editor has it: the host's own, or a session's
/// document, whose edits the session saves and previews.
pub enum TlSource {
    Own(Box<SourceDocument>),
    Session(Document),
}

/// What `body` answers for a source: `none` for a null source or a panic.
unsafe fn on_source<T>(source: Source, none: T, body: impl FnOnce(&mut TlSource) -> T) -> T {
    let source = unsafe { source.as_mut() };
    source
        .and_then(|source| caught(|| body(source)))
        .unwrap_or(none)
}

unsafe fn on_doc<T>(source: Source, none: T, body: impl FnOnce(&mut SourceDocument) -> T) -> T {
    unsafe { on_source(source, none, |source| source.with(body)) }
}

impl TlSource {
    fn with<T>(&mut self, body: impl FnOnce(&mut SourceDocument) -> T) -> T {
        match self {
            Self::Own(doc) => body(doc),
            Self::Session(document) => document.with(body),
        }
    }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_session_source(
    handle: *const TlHandle,
    session: u64,
    path: Str,
) -> Source {
    let (Some(handle), Some(path)) = (unsafe { handle.as_ref() }, unsafe { str_arg(path) }) else {
        return null_mut();
    };
    let source = caught(|| {
        let document = handle.host.sessions.document(session, path)?;
        // A visit's closers and snippet are over with it.
        document.reset_typing();
        Some(Box::new(TlSource::Session(document)))
    });
    source.flatten().map_or(null_mut(), Box::into_raw)
}

/// Not caught: reading a text into lines can't panic, and there is no
/// source to answer without one.
///
/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_new(text: Bytes, len: usize) -> Source {
    let doc = SourceDocument::new(&unsafe { text_arg(text, len) });
    Box::into_raw(Box::new(TlSource::Own(Box::new(doc))))
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_edit(
    source: Source,
    start: u32,
    length: u32,
    text: Bytes,
    len: usize,
    changing: *const TextRange,
    mirroring: bool,
) -> *mut c_char {
    let text = unsafe { text_arg(text, len) };
    let changing = unsafe { changing.as_ref() }.copied();
    let mirror = |source: &mut TlSource| {
        match source {
            TlSource::Own(doc) => doc.edit(start, length, &text),
            TlSource::Session(document) => document.edit(start, length, &text),
        }
        let delta = text.encode_utf16().count() as i64 - i64::from(length);
        source.with(|doc| {
            doc.follow(TextRange { start, length }, delta, changing, mirroring);
            let edits = (!mirroring).then(|| doc.mirror_snippet());
            serde_json::to_string(&edits.filter(|edits| !edits.is_empty())?).ok()
        })
    };
    string_out(unsafe { on_source(source, None, mirror) })
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_select(
    source: Source,
    start: u32,
    length: u32,
    mirroring: bool,
) {
    let selection = TextRange { start, length };
    unsafe { on_doc(source, (), |doc| doc.select(selection, mirroring)) }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_text(source: Source, len: *mut usize) -> *mut u8 {
    let Some(len) = (unsafe { len.as_mut() }) else {
        return null_mut();
    };
    let text = unsafe { on_doc(source, String::new(), |doc| doc.text()) };
    slice_out(text.into_bytes(), len)
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free_text(text: *mut u8, len: usize) {
    unsafe { free_slice(text, len) }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_reload(source: Source, text: Bytes, len: usize) {
    let text = unsafe { text_arg(text, len) };
    let reload = |source: &mut TlSource| match source {
        TlSource::Own(doc) => **doc = SourceDocument::new(&text),
        TlSource::Session(document) => document.reload(&text),
    };
    unsafe { on_source(source, (), reload) }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_at(source: Source, offset: u32) -> u32 {
    unsafe { on_doc(source, 0, |doc| doc.line_at(offset)) }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_start(source: Source, line: u32) -> u32 {
    unsafe { on_doc(source, 0, |doc| doc.line_start(line)) }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_count(source: Source) -> u32 {
    unsafe { on_doc(source, 0, |doc| doc.line_count()) }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_highlights(
    source: Source,
    start: u32,
    length: u32,
    count: *mut usize,
) -> *mut u32 {
    let Some(count) = (unsafe { count.as_mut() }) else {
        return null_mut();
    };
    let runs = |doc: &mut SourceDocument| {
        let runs = doc.highlights(start, length).into_iter();
        runs.flat_map(|h| [h.start, h.length, h.kind as u32])
            .collect()
    };
    slice_out(unsafe { on_doc(source, Vec::new(), runs) }, count)
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free_runs(runs: *mut u32, count: usize) {
    unsafe { free_slice(runs, count) }
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_call(source: Source, command: Str, args: Str) -> *mut c_char {
    let (Some(command), Some(args)) = (unsafe { str_arg(command) }, unsafe { str_arg(args) })
    else {
        return null_mut();
    };
    string_out(unsafe { on_doc(source, None, |doc| doc.call(command, args)) })
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_syntax_call(command: Str, args: Str) -> *mut c_char {
    let (Some(command), Some(args)) = (unsafe { str_arg(command) }, unsafe { str_arg(args) })
    else {
        return null_mut();
    };
    string_out(caught(|| syntax::call(command, args)).flatten())
}

/// # Safety
/// See the crate's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free(source: Source) {
    if !source.is_null() {
        drop(unsafe { Box::from_raw(source) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A panic in a call on a source answers as a null source does, and one
    /// before an async call's `done` is called still answers it.
    #[test]
    fn panics_stay_on_this_side() {
        let source = unsafe { tl_source_new(b"x".as_ptr(), 1) };
        assert_eq!(unsafe { on_doc(source, 7, |_| panic!("inside")) }, 7);
        assert_eq!(unsafe { tl_source_line_count(source) }, 1, "it still works");
        unsafe { tl_source_free(source) };

        extern "C" fn keep(ctx: *mut c_void, json: Str) {
            let json = unsafe { CStr::from_ptr(json) }.to_str().unwrap();
            *unsafe { &mut *ctx.cast::<Value>() } = serde_json::from_str(json).unwrap();
        }
        let mut kept = Value::Null;
        let done = Done(Some(Callback(keep, (&raw mut kept).cast())));
        let _ = std::thread::spawn(move || {
            let _done = done;
            panic!("before answering");
        })
        .join();
        assert_eq!(kept["status"], 500);
    }
}
