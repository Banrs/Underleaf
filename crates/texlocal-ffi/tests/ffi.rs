// Round trips through the C ABI exactly as a native host drives it.

use std::ffi::{CStr, CString, c_char, c_void};
use std::path::Path;
use std::ptr;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use texlocal_core::syntax::TextRange;
use texlocal_ffi::{
    TlHandle, TlSource, tl_call, tl_call_async, tl_close, tl_free, tl_open, tl_session_source,
    tl_set_listener, tl_source_call, tl_source_edit, tl_source_free, tl_source_free_runs,
    tl_source_free_text, tl_source_highlights, tl_source_line_at, tl_source_line_count,
    tl_source_line_start, tl_source_new, tl_source_reload, tl_source_select, tl_source_text,
    tl_syntax_call,
};

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

/// The JSON a call answered, read and handed back to the library to free; None
/// for no answer.
unsafe fn take_json(out: *mut c_char) -> Option<Value> {
    if out.is_null() {
        return None;
    }
    let value = serde_json::from_str(unsafe { CStr::from_ptr(out) }.to_str().unwrap()).unwrap();
    unsafe { tl_free(out) };
    Some(value)
}

/// An edit the editor made, as it says it would make it: the mirror edits the
/// source answers, if any.
unsafe fn edit(source: *mut TlSource, start: u32, length: u32, text: &[u8]) -> Option<Value> {
    let changing = TextRange { start, length };
    let (bytes, len, changing) = (text.as_ptr(), text.len(), &raw const changing);
    unsafe {
        take_json(tl_source_edit(
            source, start, length, bytes, len, changing, false,
        ))
    }
}

/// The source's whole text.
unsafe fn text_of(source: *mut TlSource) -> String {
    let mut len = 0;
    let bytes = unsafe { tl_source_text(source, &raw mut len) };
    let text = String::from_utf8(unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec());
    unsafe { tl_source_free_text(bytes, len) };
    text.unwrap()
}

/// A command to a source mirror, as the editor sends one.
unsafe fn source_call(source: *mut TlSource, command: &str, args: Value) -> Option<Value> {
    let args = c(&args.to_string());
    unsafe { take_json(tl_source_call(source, c(command).as_ptr(), args.as_ptr())) }
}

/// `command` through `tl_call`, its arguments null for none.
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

/// A handle over `data` holding one blank project, `P`.
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

/// A session on `P` with main.tex open in it: the session's number.
fn open_main(handle: *const TlHandle) -> u64 {
    let opened = call(handle, "session_open", json!({ "id": "P", "session": 1 }));
    let session = opened["ok"]["session"].as_u64().unwrap();
    let args = json!({ "session": session, "path": "main.tex" });
    let opened = call(handle, "session_open_document", args);
    assert_eq!(opened, json!({ "ok": null }));
    session
}

/// The source of a document `session` has open.
unsafe fn session_source(handle: *const TlHandle, session: u64, path: &str) -> *mut TlSource {
    unsafe { tl_session_source(handle, session, c(path).as_ptr()) }
}

#[test]
fn commands_round_trip_through_the_c_abi() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());
    assert_eq!(call_raw(handle, "list_projects", None)["ok"][0]["id"], "P");

    std::fs::write(dir.path().join("P/a.tex"), "x").unwrap();
    let found = call(handle, "search_project", json!({ "id": "P", "query": "x" }));
    assert_eq!(
        found["ok"],
        json!([{ "file": "a.tex", "hits": [{ "file": "a.tex", "line": 1, "column": 0, "length": 1, "before": "", "match": "x", "after": "" }] }])
    );

    // Errors come back as an envelope with the core's status, never a crash.
    let bad = call(handle, "create_entry", json!({ "id": "P", "path": "../x" }));
    assert_eq!(bad["status"], 400);
    assert_eq!(call_raw(handle, "nope", None)["status"], 404);

    unsafe { tl_close(handle) };
}

#[test]
fn native_only_commands_resolve_absolute_paths() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());

    let escape = call(handle, "project_root", json!({ "id": "../x" }));
    assert_eq!(escape["status"], 400);
    let root = call(handle, "project_root", json!({ "id": "P" }));
    assert!(root["ok"].as_str().unwrap().ends_with("P"));

    let dest = dir.path().join("out.zip");
    let args = json!({ "id": "P", "dest": dest.to_str().unwrap() });
    assert_eq!(call(handle, "export_zip", args), json!({ "ok": null }));
    assert!(dest.is_file());

    unsafe { tl_close(handle) };
}

#[test]
fn null_and_malformed_inputs_are_rejected_safely() {
    let out = call_raw(ptr::null(), "list_projects", None);
    assert_eq!(out["status"], 400);
    // The host names its library folder: there is no default.
    assert!(unsafe { tl_open(ptr::null()) }.is_null());

    let dir = tempfile::tempdir().unwrap();
    let handle = open(dir.path());
    let bad = call_raw(handle, "list_projects", Some("{not json"));
    assert_eq!(bad["status"], 400);
    // Import arguments of the wrong type are the caller's mistake, not an I/O error.
    for args in [
        json!({ "id": "P", "paths": [42] }),
        json!({ "id": "P", "conflict": "merge" }),
    ] {
        assert_eq!(call(handle, "import_files", args)["status"], 400);
    }
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
        // Offsets count UTF-16 units: "é " is two.
        assert_eq!(edit(source, 2, 0, b"\n"), None);
        assert_eq!(tl_source_line_at(source, 3), 2);
        let mut count = 0;
        let runs = tl_source_highlights(source, 0, 20, &raw mut count);
        assert_eq!(std::slice::from_raw_parts(runs, count), [3, 5, 0]);
        tl_source_free_runs(runs, count);
        assert_eq!(text_of(source), "é \n\\emph{x}");
        let symbol = json!({ "command": "\\alpha", "selection": { "start": 0, "length": 1 } });
        assert_eq!(
            source_call(source, "insert_symbol", symbol),
            Some(
                json!({ "edit": { "start": 0, "length": 1, "text": "$\\alpha$" }, "caret": 8, "fields": [] })
            )
        );
        let maths = source_call(source, "math_at", json!({ "caret": 1 }));
        assert_eq!(maths, Some(Value::Null), "é isn't maths");
        assert_eq!(source_call(source, "unknown", json!({})), None);
        tl_source_free(source);

        // A U+0000 is text like any other: it doesn't end the mirror's copy.
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
        // The snippet lasts while the selection is in its fields.
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

/// The commands that need no source, on any thread: Windows asks for its
/// theme's colours this way.
#[test]
fn syntax_commands_round_trip_through_the_c_abi() {
    let light = json!({ "theme": "overleaf", "dark": false, "background": [1, 1, 1, 1], "fill": [0, 0, 0, 0.08] });
    unsafe {
        let args = c(&light.to_string());
        let colors = take_json(tl_syntax_call(c("theme_colors").as_ptr(), args.as_ptr()));
        assert_eq!(colors.unwrap().as_array().map(Vec::len), Some(9));
        // An unknown command or theme, or a null string, is no answer.
        assert!(tl_syntax_call(c("no such command").as_ptr(), c("{}").as_ptr()).is_null());
        let unknown = c(r#"{"theme": "solarized"}"#);
        assert!(tl_syntax_call(c("theme_colors").as_ptr(), unknown.as_ptr()).is_null());
        assert!(tl_syntax_call(ptr::null(), c("{}").as_ptr()).is_null());
        assert!(tl_syntax_call(c("themes").as_ptr(), ptr::null()).is_null());
    }
}

#[test]
fn the_source_mirror_answers_null_and_garbage_without_unwinding() {
    unsafe {
        let none: *mut TlSource = ptr::null_mut();
        assert_eq!(edit(none, 0, 0, b"x"), None);
        tl_source_select(none, 0, 0, false);
        assert_eq!(text_of(none), "");
        assert_eq!(tl_source_line_at(none, 0), 0);
        assert_eq!(tl_source_line_start(none, 1), 0);
        assert_eq!(tl_source_line_count(none), 0);
        let mut count = 7;
        let runs = tl_source_highlights(none, 0, 1, &raw mut count);
        assert_eq!(count, 0, "no runs");
        tl_source_free_runs(runs, count);
        assert!(tl_source_call(none, c("partner").as_ptr(), c("{}").as_ptr()).is_null());
        tl_source_free(none);

        let source = tl_source_new(ptr::null(), 0);
        assert!(!source.is_null());
        let partner = c("partner");
        assert!(tl_source_call(source, partner.as_ptr(), c("{not json").as_ptr()).is_null());
        assert!(tl_source_call(source, ptr::null(), c("{}").as_ptr()).is_null());
        assert!(tl_source_call(source, partner.as_ptr(), ptr::null()).is_null());
        // The text can't be freed without its length, so a null length gets none.
        assert!(tl_source_text(source, ptr::null_mut()).is_null());
        tl_source_free_text(ptr::null_mut(), 0);
        // Out-of-range offsets are cut to the text.
        edit(source, 99, 99, b"ab");
        assert_eq!(tl_source_line_start(source, 99), 0);
        let runs = tl_source_highlights(source, 99, 99, &raw mut count);
        assert_eq!(count, 0);
        tl_source_free_runs(runs, count);
        // Runs can't be freed without their count, so a null count gets none.
        assert!(tl_source_highlights(source, 0, 9, ptr::null_mut()).is_null());
        tl_source_free_runs(ptr::null_mut(), 0);

        // Bytes that aren't UTF-8 read as U+FFFD, as Swift decodes them: the
        // edit still lands, keeping the mirror in step with the editor.
        edit(source, 1, 0, b"\xff\n");
        assert_eq!(text_of(source), "a\u{fffd}\nb");
        assert_eq!(tl_source_line_count(source), 2);
        tl_source_free(source);
    }
}

/// What a C host's callback collects: each JSON text it was handed, sent on
/// to the test.
extern "C" fn collect(ctx: *mut c_void, json: *const c_char) {
    let sink = unsafe { &*(ctx as *const mpsc::Sender<Value>) };
    let json = unsafe { CStr::from_ptr(json) }.to_str().unwrap();
    let _ = sink.send(serde_json::from_str(json).unwrap());
}

/// A sink for `collect`, its `ctx`, and what comes out of it.
fn collector() -> (Box<mpsc::Sender<Value>>, mpsc::Receiver<Value>) {
    let (sink, seen) = mpsc::channel();
    (Box::new(sink), seen)
}

fn context(sink: &mpsc::Sender<Value>) -> *mut c_void {
    (sink as *const mpsc::Sender<Value>).cast_mut().cast()
}

/// The first value collected that is `found`, within 10 s.
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

/// `command` with `args` through `tl_call_async`, its answer going to `sink`.
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
        // The editor closed a bracket for the user at the start of the file.
        let typed = json!({ "selection": { "start": 0, "length": 0 }, "text": "{" });
        let key = source_call(source, "type", typed).unwrap();
        assert_eq!(key["edit"]["text"], "{}");
        edit(source, 0, 0, b"{}");
        // Typing its closer steps over it.
        let closing = json!({ "selection": { "start": 1, "length": 0 }, "text": "}" });
        let key = source_call(source, "type", closing).unwrap();
        assert_eq!(key["selection"]["start"], 2);
        tl_source_free(source);

        // A bracket closed in one visit is only text in the next.
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
    // The highlighting reads the session's text.
    let mut count = 0;
    let runs = unsafe { tl_source_highlights(source, 0, 6, &raw mut count) };
    assert_eq!(count, 3);
    unsafe { tl_source_free_runs(runs, count) };
    let saved = call(handle, "session_save", json!({ "session": session }));
    assert_eq!(saved["ok"]["saved"], true);
    let disk = std::fs::read_to_string(dir.path().join("P/main.tex")).unwrap();
    assert_eq!(disk, format!("{added}{text}"));
    until(&events, |e| e["type"] == "saved" && e["session"] == session);
    // A reload is the disk's text, not an edit to save.
    unsafe { tl_source_reload(source, b"x".as_ptr(), 1) };
    unsafe { tl_source_free(source) };
    // Without blocking: the answer comes to the callback.
    let (answered, answers) = collector();
    let args = json!({ "session": session });
    call_async(handle, "session_save", args, &answered);
    assert_eq!(until(&answers, |_| true)["ok"]["saved"], true);
    let disk = std::fs::read_to_string(dir.path().join("P/main.tex")).unwrap();
    assert_eq!(disk, format!("{added}{text}"));
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
        // Taken after them.
        call(handle, "session_save", json!({ "session": 7 }));
        let source = unsafe { session_source(handle, 7, "main.tex") };
        assert_eq!(!source.is_null(), open, "round {round}");
        unsafe { tl_source_free(source) };
    }
    unsafe { tl_close(handle) };
}
