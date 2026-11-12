use std::borrow::Cow;
use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use texlocal_core::service::Service;
use texlocal_core::session::{Document, Sessions};
use texlocal_core::{Answered, CoreError, messages};
use texlocal_latex::syntax::{Source, Syntax, TextRange};

pub struct TlHandle {
    runtime: tokio::runtime::Runtime,
    sessions: Arc<Sessions>,
}

fn caught<T>(body: impl FnOnce() -> T) -> Option<T> {
    catch_unwind(AssertUnwindSafe(body)).ok()
}

#[derive(Clone, Copy)]
struct Callback {
    call: extern "C" fn(*mut c_void, *const c_char),
    ctx: *mut c_void,
}

unsafe impl Send for Callback {}

impl Callback {
    fn send(self, said: String) {
        (self.call)(self.ctx, c_json(said).as_ptr());
    }
}

fn c_json(text: String) -> CString {
    CString::new(text).expect("JSON has no interior NUL")
}

unsafe fn str_arg<'a>(ptr: *const c_char) -> Option<&'a str> {
    (!ptr.is_null()).then(|| unsafe { CStr::from_ptr(ptr) }.to_str().ok())?
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_open(
    data_dir: *const c_char,
    state_dir: *const c_char,
    helpers_dir: *const c_char,
    listener: Option<extern "C" fn(*mut c_void, *const c_char)>,
    ctx: *mut c_void,
) -> *mut TlHandle {
    let path = |ptr| unsafe { str_arg(ptr) }.map(PathBuf::from);
    let (Some(dir), Some(state), Some(call)) = (path(data_dir), path(state_dir), listener) else {
        return std::ptr::null_mut();
    };
    let helpers = path(helpers_dir);
    let callback = Callback { call, ctx };
    caught(|| {
        std::fs::create_dir_all(&dir).ok()?;
        std::fs::create_dir_all(&state).ok()?;
        let runtime = tokio::runtime::Runtime::new().ok()?;
        let listen = Box::new(move |said: String| callback.send(said));
        let sessions = {
            let _entered = runtime.enter();
            Arc::new(Sessions::new(
                Arc::new(Service::new(dir, state, helpers)),
                listen,
            ))
        };
        sessions.log_panics();
        Some(Box::new(TlHandle { runtime, sessions }))
    })
    .flatten()
    .map_or(std::ptr::null_mut(), Box::into_raw)
}

unsafe fn command_args<'a>(
    command: *const c_char,
    args_json: *const c_char,
) -> Result<(&'a str, Value), CoreError> {
    let command = unsafe { str_arg(command) }
        .ok_or_else(|| CoreError::bad_request(messages::invalid_command()))?;
    let args = unsafe { str_arg(args_json) }
        .ok_or_else(|| CoreError::bad_request(messages::unreadable_arguments()))?;
    let args = serde_json::from_str(args)
        .map_err(|e| CoreError::bad_request(messages::invalid_json(e)))?;
    Ok((command, args))
}

unsafe fn send(
    handle: *const TlHandle,
    id: u64,
    session: Option<u64>,
    command: *const c_char,
    args_json: *const c_char,
) {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    let _entered = handle.runtime.enter();
    caught(|| match unsafe { command_args(command, args_json) } {
        Ok((command, args)) => match session {
            Some(session) => handle.sessions.send_to(id, session, command, args),
            None => handle.sessions.send(id, command, args),
        },
        Err(err) => handle.sessions.refuse(id, err),
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_send(
    handle: *const TlHandle,
    id: u64,
    command: *const c_char,
    args_json: *const c_char,
) {
    unsafe { send(handle, id, None, command, args_json) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_session_send(
    handle: *const TlHandle,
    id: u64,
    session: u64,
    command: *const c_char,
    args_json: *const c_char,
) {
    unsafe { send(handle, id, Some(session), command, args_json) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

pub type TlSource = Document;

unsafe fn on_source<T: Default>(source: *mut TlSource, body: impl FnOnce(&Document) -> T) -> T {
    unsafe { source.as_ref() }
        .and_then(|source| caught(|| body(source)))
        .unwrap_or_default()
}

fn answered(body: impl FnOnce() -> Result<Value, CoreError>) -> *mut c_char {
    let answer = caught(body).unwrap_or_else(|| Err(CoreError::internal(messages::went_wrong())));
    let answer = serde_json::to_string(&Answered::from(answer));
    c_json(answer.expect("an answer is JSON")).into_raw()
}

unsafe fn answer_on(
    source: *mut TlSource,
    body: impl FnOnce(&Document) -> Result<Value, CoreError>,
) -> *mut c_char {
    answered(|| match unsafe { source.as_ref() } {
        Some(source) => body(source),
        None => Err(CoreError::bad_request(messages::no_source())),
    })
}

unsafe fn text_arg<'a>(ptr: *const u8, len: usize) -> Cow<'a, str> {
    if ptr.is_null() {
        return Cow::Borrowed("");
    }
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_session_source(
    handle: *const TlHandle,
    session: u64,
    path: *const c_char,
) -> *mut TlSource {
    let (Some(handle), Some(path)) = (unsafe { handle.as_ref() }, unsafe { str_arg(path) }) else {
        return std::ptr::null_mut();
    };
    caught(|| handle.sessions.document(session, path))
        .flatten()
        .map(Box::new)
        .map_or(std::ptr::null_mut(), Box::into_raw)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_new(text: *const u8, len: usize) -> *mut TlSource {
    let text = unsafe { text_arg(text, len) };
    own(|| Document::detached(&text))
}

fn own(make: impl FnOnce() -> Document) -> *mut TlSource {
    let document = caught(make).unwrap_or_else(|| Document::detached(""));
    Box::into_raw(Box::new(document))
}

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
    let edit = |document: &Document| {
        let mirrors = document
            .edit(start, length, &text, changing, mirroring)
            .ok_or_else(|| CoreError::conflict(messages::not_editable()))?;
        Ok(json!(mirrors))
    };
    unsafe { answer_on(source, edit) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_select(
    source: *mut TlSource,
    start: u32,
    length: u32,
    mirroring: bool,
) {
    unsafe { on_source(source, |s| s.select(TextRange { start, length }, mirroring)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_composing(source: *mut TlSource, composing: bool) {
    unsafe { on_source(source, |s| s.compose(composing)) }
}

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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free_text(text: *mut u8, len: usize) {
    if !text.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(text, len)) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_restore(source: *mut TlSource, text: *const u8, len: usize) {
    let text = unsafe { text_arg(text, len) };
    unsafe { on_source(source, |s| s.restore(&text)) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_editable(source: *mut TlSource) -> bool {
    unsafe { on_source(source, Document::editable) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_version(source: *mut TlSource) -> u64 {
    unsafe { on_source(source, Document::version) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_at(source: *mut TlSource, offset: u32) -> u32 {
    unsafe { on_source(source, |s| s.with(|doc| doc.line_at(offset))) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_start(source: *mut TlSource, line: u32) -> u32 {
    unsafe { on_source(source, |s| s.with(|doc| doc.line_start(line))) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_line_count(source: *mut TlSource) -> u32 {
    unsafe { on_source(source, |s| s.with(|doc| doc.line_count())) }
}

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
    let highlights = |document: &Document| {
        let runs = document.with(|doc| doc.highlights(start, length));
        runs.into_iter()
            .flat_map(|h| [h.start, h.length, h.kind as u32])
            .collect()
    };
    let runs: Box<[u32]> = unsafe { on_source(source, highlights) };
    *count = runs.len();
    Box::into_raw(runs).cast()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free_runs(runs: *mut u32, count: usize) {
    if !runs.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(runs, count)) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_call(
    source: *mut TlSource,
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let called = unsafe { command_args(command, args_json) };
    let call = |document: &Document| {
        let (command, args) = called?;
        document
            .with(|doc| Source::call(doc, command, args))
            .map_err(CoreError::bad_request)
    };
    unsafe { answer_on(source, call) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_syntax_call(
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let called = unsafe { command_args(command, args_json) };
    answered(|| {
        let (command, args) = called?;
        Syntax::call(command, args).map_err(CoreError::bad_request)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tl_source_free(source: *mut TlSource) {
    if !source.is_null() {
        drop(unsafe { Box::from_raw(source) });
    }
}

#[cfg(test)]
mod tests;
