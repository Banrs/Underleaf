//! Round trips through the C ABI exactly as a native host drives it.

use std::path::Path;
use std::ptr;
use std::sync::mpsc;
use std::time::Duration;

use super::*;

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

unsafe fn take_json(out: *mut c_char) -> Option<Value> {
    (!out.is_null()).then(|| {
        let json = unsafe { CStr::from_ptr(out) }.to_str().unwrap();
        let value = serde_json::from_str(json).unwrap();
        unsafe { tl_free(out) };
        value
    })
}

unsafe fn edit(source: *mut TlSource, start: u32, length: u32, text: &[u8]) -> Option<Value> {
    let range = TextRange { start, length };
    let (bytes, len, range) = (text.as_ptr(), text.len(), &raw const range);
    unsafe {
        take_json(tl_source_edit(
            source, start, length, bytes, len, range, false,
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

/// The answer, waited for. The sink is leaked: `done` may still be returning from its send.
fn call_raw(handle: *const TlHandle, command: &str, args: Option<&str>) -> Value {
    let args = args.map(c);
    let args = args.as_ref().map_or(ptr::null(), |a| a.as_ptr());
    let (sink, answer) = mpsc::channel();
    let ctx = context(Box::leak(Box::new(sink)));
    unsafe { tl_call_async(handle, c(command).as_ptr(), args, Some(collect), ctx) };
    until(&answer, |_| true)
}

fn call(handle: *const TlHandle, command: &str, args: Value) -> Value {
    call_raw(handle, command, Some(&args.to_string()))
}

extern "C" fn ignore(_ctx: *mut c_void, _json: *const c_char) {}

/// The service over `data`, telling `listener` its events, holding a blank project "P".
fn open(data: &Path, listener: Done, ctx: *mut c_void) -> *mut TlHandle {
    let data = c(data.to_str().unwrap());
    let handle = unsafe { tl_open(data.as_ptr(), Some(listener), ctx) };
    assert!(!handle.is_null());
    let blank = json!({ "name": "P", "template": "blank" });
    assert_eq!(call(handle, "create_project", blank)["ok"]["id"], "P");
    handle
}

fn open_main(handle: *const TlHandle) -> u64 {
    call(handle, "session_open", json!({ "id": "P", "session": 1 }));
    let main = json!({ "session": 1, "path": "main.tex" });
    assert_eq!(
        call(handle, "session_open_document", main),
        json!({ "ok": null })
    );
    1
}

unsafe fn session_source(handle: *const TlHandle, session: u64, path: &str) -> *mut TlSource {
    unsafe { tl_session_source(handle, session, c(path).as_ptr()) }
}

#[test]
fn commands_and_bad_input_answer_through_the_c_abi() {
    assert_eq!(
        call_raw(ptr::null(), "list_projects", None)["kind"],
        "invalid"
    );
    let dir = tempfile::tempdir().unwrap();
    let path = c(dir.path().to_str().unwrap());
    let null = ptr::null_mut();
    assert!(unsafe { tl_open(ptr::null(), Some(ignore), null) }.is_null());
    assert!(unsafe { tl_open(path.as_ptr(), None, null) }.is_null());

    let handle = open(dir.path(), ignore, null);
    assert_eq!(call_raw(handle, "list_projects", None)["ok"][0]["id"], "P");
    assert_eq!(
        call_raw(handle, "list_projects", Some("{not json"))["kind"],
        "invalid"
    );
    assert_eq!(call_raw(handle, "nope", None)["kind"], "notFound");
    unsafe {
        tl_free(ptr::null_mut());
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
        let maths = source_call(source, "math_at", json!({ "caret": 1 }));
        assert_eq!(maths, Some(Value::Null), "é isn't maths");
        assert_eq!(source_call(source, "unknown", json!({})), None);
        // Bytes that aren't UTF-8 read as U+FFFD, as Swift decodes them, so the edit lands with
        // the editor's length; past the text, it lands at its end.
        edit(source, 99, 99, b"\xff\0c");
        assert_eq!(text_of(source), "é \n\\emph{x}\u{fffd}\0c");
        tl_source_free(source);
        assert_eq!(edit(ptr::null_mut(), 0, 0, b"x"), None);
    }
}

#[test]
fn syntax_commands_round_trip_through_the_c_abi() {
    let args = c(r"{}");
    let menus = unsafe { take_json(tl_syntax_call(c("menus").as_ptr(), args.as_ptr())) };
    assert!(menus.unwrap()["templates"].is_object());
    assert!(unsafe { tl_syntax_call(ptr::null(), c("{}").as_ptr()) }.is_null());
}

/// A session's document source edits the session's document: a save writes its edits, it
/// answers the version a replace is made against, and shown again it keeps no typing state.
#[test]
fn a_session_documents_source_is_the_sessions_document() {
    let dir = tempfile::tempdir().unwrap();
    let (sink, events) = mpsc::channel();
    // The handle outlives the test, as the app's does, and may tell its listener after it.
    let handle = open(dir.path(), collect, context(Box::leak(Box::new(sink))));
    let session = open_main(handle);
    let typed = |at: u32, text: &str| json!({ "selection": { "start": at, "length": 0 }, "text": text, "autoPair": true });
    unsafe {
        let source = session_source(handle, session, "main.tex");
        let text = text_of(source);
        edit(source, 0, 0, b"% zebra\n");
        let args = json!({ "session": session, "query": "zebra", "replacement": "okapi" });
        let replaced = call(handle, "session_replace", args);
        let version = source_call(source, "version", json!({}));
        assert_eq!(version.as_ref(), Some(&replaced["ok"]["edits"]["version"]));
        call(handle, "session_save", json!({ "session": session }));
        let disk = std::fs::read_to_string(dir.path().join("P/main.tex")).unwrap();
        assert_eq!(disk, format!("% zebra\n{text}"));
        until(&events, |e| e["type"] == "saved" && e["session"] == session);
        source_call(source, "type", typed(0, "("));
        edit(source, 0, 0, b"()");
        tl_source_free(source);

        let source = session_source(handle, session, "main.tex");
        let key = source_call(source, "type", typed(1, ")")).unwrap();
        assert_eq!(key["selection"], Value::Null, "the closer was forgotten");
        tl_source_free(source);

        let own = tl_source_new(ptr::null(), 0);
        assert_eq!(source_call(own, "version", json!({})), Some(Value::Null));
        tl_source_free(own);
    }
}

extern "C" fn collect(ctx: *mut c_void, json: *const c_char) {
    let sink = unsafe { &*(ctx as *const mpsc::Sender<Value>) };
    let json = unsafe { CStr::from_ptr(json) }.to_str().unwrap();
    let _ = sink.send(serde_json::from_str(json).unwrap());
}

fn context<T>(ctx: &T) -> *mut c_void {
    (ctx as *const T).cast_mut().cast()
}

fn until(seen: &mpsc::Receiver<Value>, found: impl Fn(&Value) -> bool) -> Value {
    let next = || {
        seen.recv_timeout(Duration::from_secs(10))
            .expect("collected in time")
    };
    std::iter::repeat_with(next).find(found).unwrap()
}

type Done = extern "C" fn(*mut c_void, *const c_char);

fn call_async(handle: *const TlHandle, command: &str, args: Value, done: Done, ctx: *mut c_void) {
    let (command, args) = (c(command), c(&args.to_string()));
    unsafe { tl_call_async(handle, command.as_ptr(), args.as_ptr(), Some(done), ctx) };
}

#[test]
fn a_session_takes_its_commands_in_the_order_they_were_sent_without_waiting() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open(dir.path(), ignore, ptr::null_mut());
    let (sink, answers) = mpsc::channel();
    // The handle outlives the test, as the app's does, and may call `done` after it.
    let sink = Box::leak(Box::new(sink));
    let seven = json!({ "id": "P", "session": 7 });
    call_async(handle, "session_open", seven, collect, context(sink));
    assert_eq!(until(&answers, |_| true)["ok"]["name"], "P");
    let main = json!({ "session": 7, "path": "main.tex" });
    let commands = ["session_open_document", "session_close_document"];
    for round in 0..50 {
        let open = round % 2 == 0;
        for command in commands.iter().cycle().skip(usize::from(open)).take(4) {
            call_async(handle, command, main.clone(), collect, context(sink));
        }
        call(handle, "session_save", json!({ "session": 7 }));
        let source = unsafe { session_source(handle, 7, "main.tex") };
        assert_eq!(!source.is_null(), open, "round {round}");
        unsafe { tl_source_free(source) };
    }
}

/// As a host's continuation may, resumed on the thread that answered.
#[test]
fn a_session_commands_done_may_call_the_core() {
    extern "C" fn call_within(ctx: *mut c_void, _json: *const c_char) {
        let (handle, sink) = unsafe { &*(ctx as *const (*mut TlHandle, mpsc::Sender<Value>)) };
        let _ = sink.send(call(*handle, "list_projects", json!({})));
    }
    let dir = tempfile::tempdir().unwrap();
    let handle = open(dir.path(), ignore, ptr::null_mut());
    open_main(handle);
    let (sink, answers) = mpsc::channel();
    let (within, save) = (Box::leak(Box::new((handle, sink))), json!({ "session": 1 }));
    call_async(handle, "session_save", save, call_within, context(within));
    assert_eq!(until(&answers, |_| true)["ok"][0]["id"], "P");
}
