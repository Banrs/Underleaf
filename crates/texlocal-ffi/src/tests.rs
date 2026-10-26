use std::ffi::{CStr, CString, c_char, c_void};
use std::ptr;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Duration;

use serde_json::{Value, json};

use super::*;

extern "C" fn collect(ctx: *mut c_void, json: *const c_char) {
    let sender = unsafe { &*(ctx as *const Sender<Value>) };
    let text = unsafe { CStr::from_ptr(json) }.to_str().unwrap();
    let _ = sender.send(serde_json::from_str(text).unwrap());
}

struct Core {
    handle: *mut TlHandle,
    events: Receiver<Value>,
    _dir: tempfile::TempDir,
    _sender: Box<Sender<Value>>,
}

impl Core {
    fn open() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let (sender, events) = channel();
        let sender = Box::new(sender);
        let path = c(dir.path().to_str().unwrap());
        let ctx = (&raw const *sender).cast_mut().cast::<c_void>();
        let handle = unsafe { tl_open(path.as_ptr(), Some(collect), ctx) };
        assert!(!handle.is_null());
        Self {
            handle,
            events,
            _dir: dir,
            _sender: sender,
        }
    }

    fn call(&self, command: &str, args: Value) -> Value {
        call_raw(self.handle, Some(command), Some(&args.to_string()))
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        drop(unsafe { Box::from_raw(self.handle) });
    }
}

fn c(text: &str) -> CString {
    CString::new(text).unwrap()
}

fn call_raw(handle: *const TlHandle, command: Option<&str>, args: Option<&str>) -> Value {
    let (sender, answers) = channel::<Value>();
    let command = command.map(c);
    let args = args.map(c);
    unsafe {
        tl_call_async(
            handle,
            command.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            args.as_ref().map_or(ptr::null(), |a| a.as_ptr()),
            Some(collect),
            (&raw const sender).cast_mut().cast::<c_void>(),
        );
    }
    answers.recv_timeout(Duration::from_secs(10)).unwrap()
}

fn source_text(source: *mut TlSource) -> String {
    let mut len = 0;
    let bytes = unsafe { tl_source_text(source, &raw mut len) };
    let text =
        String::from_utf8(unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec()).unwrap();
    unsafe { tl_source_free_text(bytes, len) };
    text
}

fn take(text: *mut c_char) -> Option<Value> {
    if text.is_null() {
        return None;
    }
    let value = serde_json::from_str(unsafe { CStr::from_ptr(text) }.to_str().unwrap()).unwrap();
    unsafe { tl_free(text) };
    Some(value)
}

#[test]
fn opening_needs_a_folder_and_a_listener() {
    let dir = c("/tmp");
    assert!(unsafe { tl_open(ptr::null(), Some(collect), ptr::null_mut()) }.is_null());
    assert!(unsafe { tl_open(dir.as_ptr(), None, ptr::null_mut()) }.is_null());
}

#[test]
fn a_command_answers_ok_or_an_error_kind() {
    let core = Core::open();
    assert_eq!(core.call("list_projects", json!({})), json!({ "ok": [] }));
    assert_eq!(core.call("nope", json!({}))["kind"], "notFound");
    assert_eq!(
        call_raw(core.handle, Some("list_projects"), Some("{not json"))["kind"],
        "invalid"
    );
    assert_eq!(call_raw(core.handle, None, None)["kind"], "invalid");
    assert_eq!(
        call_raw(ptr::null(), Some("list_projects"), None)["kind"],
        "invalid"
    );
}

#[test]
fn a_session_document_is_edited_and_saved_through_the_abi() {
    let core = Core::open();
    core.call(
        "create_project",
        json!({ "name": "P", "template": "blank" }),
    );
    core.call("session_open", json!({ "id": "P", "session": 7 }));
    core.call(
        "session_open_document",
        json!({ "session": 7, "path": "main.tex" }),
    );
    let path = c("main.tex");
    let source = unsafe { tl_session_source(core.handle, 7, path.as_ptr()) };
    assert!(!source.is_null());
    let before = source_text(source);
    let note = "% note\n";
    let mirrored =
        unsafe { tl_source_edit(source, 0, 0, note.as_ptr(), note.len(), ptr::null(), false) };
    assert_eq!(
        take(mirrored),
        None,
        "an edit outside a snippet mirrors nothing"
    );
    assert_eq!(source_text(source), format!("{note}{before}"));
    unsafe { tl_source_free(source) };
    assert_eq!(
        core.call("session_save", json!({ "session": 7 }))["ok"]["saved"],
        true
    );
    let saved = std::fs::read_to_string(core._dir.path().join("P/main.tex")).unwrap();
    assert!(saved.starts_with(note));
}

#[test]
fn session_events_reach_the_listener() {
    let core = Core::open();
    core.call(
        "create_project",
        json!({ "name": "P", "template": "article" }),
    );
    core.call("session_open", json!({ "id": "P", "session": 1 }));
    let found = (0..50)
        .filter_map(|_| core.events.recv_timeout(Duration::from_millis(200)).ok())
        .find(|event| event["type"] == "outline");
    assert_eq!(found.unwrap()["session"], 1);
}

#[test]
fn a_source_of_the_hosts_own_highlights_and_answers_commands() {
    let text = "\\emph{a} % b";
    let source = unsafe { tl_source_new(text.as_ptr(), text.len()) };
    let mut count = 0;
    let runs = unsafe { tl_source_highlights(source, 0, text.len() as u32, &raw mut count) };
    let triples = unsafe { std::slice::from_raw_parts(runs, count) }.to_vec();
    unsafe { tl_source_free_runs(runs, count) };
    assert_eq!(&triples[..3], [0, 5, 0]);
    assert_eq!(unsafe { tl_source_line_count(source) }, 1);
    let command = c("toggle_comment");
    let args = c(r#"{"selections":[{"start":0,"length":0}]}"#);
    let answer = take(unsafe { tl_source_call(source, command.as_ptr(), args.as_ptr()) }).unwrap();
    assert!(answer.is_array());
    let unknown = c("nope");
    assert!(unsafe { tl_source_call(source, unknown.as_ptr(), args.as_ptr()) }.is_null());
    unsafe { tl_source_free(source) };
}

#[test]
fn syntax_commands_need_no_source() {
    let menus = c("menus");
    let empty = c("{}");
    let answer = take(unsafe { tl_syntax_call(menus.as_ptr(), empty.as_ptr()) }).unwrap();
    assert!(answer["templates"].is_object());
    assert!(unsafe { tl_syntax_call(ptr::null(), empty.as_ptr()) }.is_null());
}
