//! Round trips through the C ABI exactly as a native host drives it.

use std::path::Path;
use std::ptr;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use super::*;

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

unsafe fn take_json(out: *mut c_char) -> Option<Value> {
    if out.is_null() {
        return None;
    }
    let value = serde_json::from_str(unsafe { CStr::from_ptr(out) }.to_str().unwrap()).unwrap();
    unsafe { tl_free(out) };
    Some(value)
}

unsafe fn edit(source: *mut TlSource, start: u32, length: u32, text: &[u8]) -> Option<Value> {
    let changing = TextRange { start, length };
    let (bytes, len, changing) = (text.as_ptr(), text.len(), &raw const changing);
    unsafe {
        take_json(tl_source_edit(
            source, start, length, bytes, len, changing, false,
        ))
    }
}

unsafe fn text_of(source: *mut TlSource) -> String {
    let mut len = 0;
    let bytes = unsafe { tl_source_text(source, &raw mut len) };
    let text = String::from_utf8(unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec());
    unsafe { tl_source_free_text(bytes, len) };
    text.unwrap()
}

unsafe fn source_call(source: *mut TlSource, command: &str, args: Value) -> Option<Value> {
    let args = c(&args.to_string());
    unsafe { take_json(tl_source_call(source, c(command).as_ptr(), args.as_ptr())) }
}

fn call_raw(handle: *const TlHandle, command: &str, args: Option<&str>) -> Value {
    let args = args.map(c);
    let args = args.as_ref().map_or(ptr::null(), |a| a.as_ptr());
    unsafe { take_json(tl_call(handle, c(command).as_ptr(), args)).unwrap() }
}

fn call(handle: *const TlHandle, command: &str, args: Value) -> Value {
    call_raw(handle, command, Some(&args.to_string()))
}

fn open(data: &Path) -> *mut TlHandle {
    let handle = unsafe { tl_open(c(data.to_str().unwrap()).as_ptr()) };
    assert!(!handle.is_null());
    handle
}

fn open_with_project(data: &Path) -> *mut TlHandle {
    let handle = open(data);
    let created = call(
        handle,
        "create_project",
        json!({ "name": "P", "template": "blank" }),
    );
    assert_eq!(created["ok"]["id"], "P");
    handle
}

fn open_main(handle: *const TlHandle) -> u64 {
    let opened = call(handle, "session_open", json!({ "id": "P", "session": 1 }));
    let session = opened["ok"]["session"].as_u64().unwrap();
    let args = json!({ "session": session, "path": "main.tex" });
    let opened = call(handle, "session_open_document", args);
    assert_eq!(opened, json!({ "ok": null }));
    session
}

unsafe fn session_source(handle: *const TlHandle, session: u64, path: &str) -> *mut TlSource {
    unsafe { tl_session_source(handle, session, c(path).as_ptr()) }
}

#[test]
fn commands_round_trip_through_the_c_abi() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());
    assert_eq!(call_raw(handle, "list_projects", None)["ok"][0]["id"], "P");

    let bad = call(handle, "create_entry", json!({ "id": "P", "path": "../x" }));
    assert_eq!(bad["status"], 400);
    assert_eq!(call_raw(handle, "nope", None)["status"], 404);

    unsafe { tl_close(handle) };
}

#[test]
fn null_and_malformed_inputs_are_rejected_safely() {
    let out = call_raw(ptr::null(), "list_projects", None);
    assert_eq!(out["status"], 400);
    assert!(unsafe { tl_open(ptr::null()) }.is_null());

    let dir = tempfile::tempdir().unwrap();
    let handle = open(dir.path());
    let bad = call_raw(handle, "list_projects", Some("{not json"));
    assert_eq!(bad["status"], 400);
    unsafe {
        tl_free(ptr::null_mut());
        tl_close(handle);
        tl_close(ptr::null_mut());
    }
}

#[test]
fn the_source_mirror_round_trips_through_the_c_abi() {
    unsafe {
        let text = "é \\emph{x}";
        let source = tl_source_new(text.as_ptr(), text.len());
        assert_eq!(edit(source, 2, 0, b"\n"), None);
        assert_eq!(tl_source_line_at(source, 3), 2);
        let mut count = 0;
        let runs = tl_source_highlights(source, 0, 20, &raw mut count);
        assert_eq!(std::slice::from_raw_parts(runs, count), [3, 5, 0]);
        tl_source_free_runs(runs, count);
        assert_eq!(text_of(source), "é \n\\emph{x}");
        let maths = source_call(source, "math_at", json!({ "caret": 1 }));
        assert_eq!(maths, Some(Value::Null), "é isn't maths");
        assert_eq!(source_call(source, "unknown", json!({})), None);
        tl_source_free(source);

        let text = "a\0\nb";
        let source = tl_source_new(text.as_ptr(), text.len());
        assert_eq!(tl_source_line_count(source), 2);
        edit(source, 4, 0, b"\0c");
        assert_eq!(text_of(source), "a\u{0}\nb\u{0}c");
        tl_source_free(source);

        // What's typed in a snippet's field goes in its other places: the edit
        // answers those edits, which go in as mirroring and answer none.
        let text = "\\begin{}\n\\end{}";
        let source = tl_source_new(text.as_ptr(), text.len());
        let fields = json!([{ "start": 7, "length": 0, "index": 0 }, { "start": 14, "length": 0, "index": 0 }]);
        let snippet = json!({ "fields": fields, "at": 0 });
        source_call(source, "start_snippet", snippet);
        let mirror = edit(source, 7, 0, b"x");
        assert_eq!(
            mirror,
            Some(json!([{ "start": 15, "length": 0, "text": "x" }]))
        );
        let mirrored = tl_source_edit(source, 15, 0, b"x".as_ptr(), 1, ptr::null(), true);
        assert!(mirrored.is_null());
        tl_source_select(source, 8, 0, false);
        assert_eq!(text_of(source), "\\begin{x}\n\\end{x}");
        let mirror = edit(source, 8, 0, b"y");
        assert_eq!(
            mirror,
            Some(json!([{ "start": 16, "length": 1, "text": "xy" }]))
        );
        tl_source_select(source, 0, 0, false);
        assert_eq!(edit(source, 0, 0, b"%"), None);
        tl_source_free(source);
    }
}

#[test]
fn syntax_commands_round_trip_through_the_c_abi() {
    let light = json!({ "theme": "overleaf", "dark": false, "background": [1, 1, 1, 1], "fill": [0, 0, 0, 0.08] });
    unsafe {
        let args = c(&light.to_string());
        let colors = take_json(tl_syntax_call(c("theme_colors").as_ptr(), args.as_ptr()));
        assert_eq!(colors.unwrap().as_array().map(Vec::len), Some(9));
        assert!(tl_syntax_call(ptr::null(), c("{}").as_ptr()).is_null());
    }
}

#[test]
fn the_source_mirror_answers_null_and_garbage_without_unwinding() {
    unsafe {
        let none: *mut TlSource = ptr::null_mut();
        assert_eq!(edit(none, 0, 0, b"x"), None);
        assert_eq!(tl_source_line_count(none), 0);
        tl_source_free(none);

        let source = tl_source_new(ptr::null(), 0);
        assert!(!source.is_null());
        let partner = c("partner");
        assert!(tl_source_call(source, partner.as_ptr(), c("{not json").as_ptr()).is_null());
        edit(source, 99, 99, b"ab");
        assert_eq!(tl_source_line_start(source, 99), 0);

        // Bytes that aren't UTF-8 read as U+FFFD, as Swift decodes them: the
        // edit still lands, keeping the mirror in step with the editor.
        edit(source, 1, 0, b"\xff\n");
        assert_eq!(text_of(source), "a\u{fffd}\nb");
        assert_eq!(tl_source_line_count(source), 2);
        tl_source_free(source);
    }
}

extern "C" fn collect(ctx: *mut c_void, json: *const c_char) {
    let sink = unsafe { &*(ctx as *const mpsc::Sender<Value>) };
    let json = unsafe { CStr::from_ptr(json) }.to_str().unwrap();
    let _ = sink.send(serde_json::from_str(json).unwrap());
}

fn collector() -> (Box<mpsc::Sender<Value>>, mpsc::Receiver<Value>) {
    let (sink, seen) = mpsc::channel();
    (Box::new(sink), seen)
}

fn context(sink: &mpsc::Sender<Value>) -> *mut c_void {
    (sink as *const mpsc::Sender<Value>).cast_mut().cast()
}

fn until(seen: &mpsc::Receiver<Value>, found: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let value = seen.recv_timeout(left).expect("collected in time");
        if found(&value) {
            return value;
        }
    }
}

fn call_async(handle: *const TlHandle, command: &str, args: Value, sink: &mpsc::Sender<Value>) {
    let (command, args) = (c(command), c(&args.to_string()));
    unsafe {
        tl_call_async(
            handle,
            command.as_ptr(),
            args.as_ptr(),
            Some(collect),
            context(sink),
        );
    }
}

#[test]
fn a_session_document_shown_again_keeps_no_typing_state_from_before() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());
    std::fs::write(dir.path().join("P/main.tex"), "").unwrap();
    let session = open_main(handle);
    unsafe {
        let source = session_source(handle, session, "main.tex");
        let typed = json!({ "selection": { "start": 0, "length": 0 }, "text": "{" });
        let key = source_call(source, "type", typed).unwrap();
        assert_eq!(key["edit"]["text"], "{}");
        edit(source, 0, 0, b"{}");
        let closing = json!({ "selection": { "start": 1, "length": 0 }, "text": "}" });
        let key = source_call(source, "type", closing).unwrap();
        assert_eq!(key["selection"]["start"], 2);
        tl_source_free(source);

        let source = session_source(handle, session, "main.tex");
        let typed = json!({ "selection": { "start": 2, "length": 0 }, "text": "(" });
        source_call(source, "type", typed);
        edit(source, 2, 0, b"()");
        tl_source_free(source);
        let source = session_source(handle, session, "main.tex");
        let closing = json!({ "selection": { "start": 3, "length": 0 }, "text": ")" });
        let key = source_call(source, "type", closing).unwrap();
        assert_eq!(key["selection"], Value::Null, "the closer was forgotten");
        tl_source_free(source);
        tl_close(handle);
    }
}

#[test]
fn a_session_saves_the_edits_its_document_source_takes_and_tells_the_listener() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());
    let (sink, events) = collector();
    unsafe { tl_set_listener(handle, Some(collect), context(&sink)) };
    let session = open_main(handle);
    let source = unsafe { session_source(handle, session, "main.tex") };
    assert!(!source.is_null());
    let text = unsafe { text_of(source) };
    assert!(unsafe { session_source(handle, session, "other.tex") }.is_null());
    let added = "% note\n";
    unsafe { edit(source, 0, 0, added.as_bytes()) };
    let mut count = 0;
    let runs = unsafe { tl_source_highlights(source, 0, 6, &raw mut count) };
    assert_eq!(count, 3);
    unsafe { tl_source_free_runs(runs, count) };
    let saved = call(handle, "session_save", json!({ "session": session }));
    assert_eq!(saved["ok"]["saved"], true);
    let disk = std::fs::read_to_string(dir.path().join("P/main.tex")).unwrap();
    assert_eq!(disk, format!("{added}{text}"));
    until(&events, |e| e["type"] == "saved" && e["session"] == session);
    unsafe { tl_source_reload(source, b"x".as_ptr(), 1) };
    unsafe { tl_source_free(source) };
    unsafe { tl_close(handle) };
}

#[test]
fn a_session_takes_its_commands_in_the_order_they_were_sent_without_waiting() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());
    let (sink, answers) = collector();
    let seven = json!({ "id": "P", "session": 7 });
    call_async(handle, "session_open", seven, &sink);
    assert_eq!(until(&answers, |_| true)["ok"]["session"], 7);
    let main = json!({ "session": 7, "path": "main.tex" });
    let commands = ["session_open_document", "session_close_document"];
    for round in 0..50 {
        let open = round % 2 == 0;
        for command in commands.iter().cycle().skip(usize::from(open)).take(4) {
            call_async(handle, command, main.clone(), &sink);
        }
        call(handle, "session_save", json!({ "session": 7 }));
        let source = unsafe { session_source(handle, 7, "main.tex") };
        assert_eq!(!source.is_null(), open, "round {round}");
        unsafe { tl_source_free(source) };
    }
    unsafe { tl_close(handle) };
}
