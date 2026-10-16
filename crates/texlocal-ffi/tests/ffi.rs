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
    let (bytes, len) = (text.as_ptr(), text.len());
    unsafe {
        take_json(tl_source_edit(
            source,
            start,
            length,
            bytes,
            len,
            &raw const changing,
            false,
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
    let command = CString::new(command).unwrap();
    let args = CString::new(args.to_string()).unwrap();
    unsafe { take_json(tl_source_call(source, command.as_ptr(), args.as_ptr())) }
}

fn call(handle: *const TlHandle, command: &str, args: Option<Value>) -> Value {
    call_raw(handle, command, args.map(|a| a.to_string()).as_deref())
}

fn call_raw(handle: *const TlHandle, command: &str, args: Option<&str>) -> Value {
    let command = CString::new(command).unwrap();
    let args = args.map(|a| CString::new(a).unwrap());
    unsafe {
        let out = tl_call(
            handle,
            command.as_ptr(),
            args.as_ref().map_or(ptr::null(), |a| a.as_ptr()),
        );
        take_json(out).unwrap()
    }
}

fn open(data: &Path) -> *mut TlHandle {
    let path = CString::new(data.to_str().unwrap()).unwrap();
    let handle = unsafe { tl_open(path.as_ptr()) };
    assert!(!handle.is_null());
    handle
}

/// A handle over `data` holding one blank project, `P`.
fn open_with_project(data: &Path) -> *mut TlHandle {
    let handle = open(data);
    let created = call(
        handle,
        "create_project",
        Some(json!({ "name": "P", "template": "blank" })),
    );
    assert_eq!(created["ok"]["id"], "P");
    handle
}

#[test]
fn commands_round_trip_through_the_c_abi() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());
    assert_eq!(call(handle, "list_projects", None)["ok"][0]["id"], "P");

    call(
        handle,
        "write_file",
        Some(json!({ "id": "P", "path": "a.tex", "text": "x" })),
    );
    assert_eq!(
        call(
            handle,
            "read_file",
            Some(json!({ "id": "P", "path": "a.tex" }))
        )["ok"]["text"],
        "x"
    );

    assert_eq!(
        call(
            handle,
            "search_project",
            Some(json!({ "id": "P", "query": "x" }))
        )["ok"],
        json!([{ "file": "a.tex", "hits": [{ "file": "a.tex", "line": 1, "before": "", "match": "x", "after": "" }] }])
    );

    // Errors come back as an envelope with the core's status, never a crash.
    let bad = call(
        handle,
        "read_file",
        Some(json!({ "id": "P", "path": "../x" })),
    );
    assert_eq!(bad["status"], 400);
    assert_eq!(call(handle, "nope", None)["status"], 404);

    unsafe { tl_close(handle) };
}

#[test]
fn native_only_commands_resolve_absolute_paths() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());

    let escape = call(handle, "project_root", Some(json!({ "id": "../x" })));
    assert_eq!(escape["status"], 400);
    let root = call(handle, "project_root", Some(json!({ "id": "P" })));
    assert!(root["ok"].as_str().unwrap().ends_with("P"));

    let dest = dir.path().join("out.zip");
    let exported = call(
        handle,
        "export_zip",
        Some(json!({ "id": "P", "dest": dest.to_str().unwrap() })),
    );
    assert_eq!(exported, json!({ "ok": null }));
    assert!(dest.is_file());

    unsafe { tl_close(handle) };
}

#[test]
fn null_and_malformed_inputs_are_rejected_safely() {
    let out = call(ptr::null(), "list_projects", None);
    assert_eq!(out["status"], 400);
    // The host names its library folder: there is no default.
    assert!(unsafe { tl_open(ptr::null()) }.is_null());

    let dir = tempfile::tempdir().unwrap();
    let handle = open(dir.path());
    assert_eq!(
        call_raw(handle, "list_projects", Some("{not json"))["status"],
        400
    );
    // Import arguments of the wrong type are the caller's mistake, not an I/O error.
    for args in [
        json!({ "id": "P", "paths": [42] }),
        json!({ "id": "P", "conflict": "merge" }),
    ] {
        assert_eq!(call(handle, "import_files", Some(args))["status"], 400);
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
        let symbol = source_call(
            source,
            "insert_symbol",
            json!({ "command": "\\alpha", "selection": { "start": 0, "length": 1 } }),
        );
        assert_eq!(
            symbol,
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
        source_call(
            source,
            "start_snippet",
            json!({ "fields": fields, "at": 0 }),
        );
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
        assert_eq!(
            edit(source, 8, 0, b"y"),
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
    let c = |s: &str| CString::new(s).unwrap();
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
    let c = |s: &str| CString::new(s).unwrap();
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

#[test]
fn a_session_document_shown_again_keeps_no_typing_state_from_before() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());
    let empty = json!({ "id": "P", "path": "main.tex", "text": "" });
    call(handle, "write_file", Some(empty));
    let opened = call(
        handle,
        "session_open",
        Some(json!({ "id": "P", "session": 1 })),
    );
    let session = opened["ok"]["session"].as_u64().unwrap();
    let args = json!({ "session": session, "path": "main.tex" });
    call(handle, "session_open_document", Some(args));
    let path = CString::new("main.tex").unwrap();
    unsafe {
        let source = tl_session_source(handle, session, path.as_ptr());
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
        let source = tl_session_source(handle, session, path.as_ptr());
        let typed = json!({ "selection": { "start": 2, "length": 0 }, "text": "(" });
        source_call(source, "type", typed);
        edit(source, 2, 0, b"()");
        tl_source_free(source);
        let source = tl_session_source(handle, session, path.as_ptr());
        let closing = json!({ "selection": { "start": 3, "length": 0 }, "text": ")" });
        let key = source_call(source, "type", closing).unwrap();
        assert_eq!(key["selection"], Value::Null, "the closer was forgotten");
        tl_source_free(source);
    }
    unsafe { tl_close(handle) };
}

#[test]
fn a_session_saves_the_edits_its_document_source_takes_and_tells_the_listener() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());
    let (sink, events) = collector();
    unsafe { tl_set_listener(handle, Some(collect), context(&sink)) };
    let opened = call(
        handle,
        "session_open",
        Some(json!({ "id": "P", "session": 1 })),
    );
    let session = opened["ok"]["session"].as_u64().unwrap();
    let args = json!({ "session": session, "path": "main.tex" });
    let opened = call(handle, "session_open_document", Some(args));
    assert_eq!(opened, json!({ "ok": null }));
    let path = CString::new("main.tex").unwrap();
    let source = unsafe { tl_session_source(handle, session, path.as_ptr()) };
    assert!(!source.is_null());
    let text = unsafe { text_of(source) };
    let missing = CString::new("other.tex").unwrap();
    assert!(unsafe { tl_session_source(handle, session, missing.as_ptr()) }.is_null());
    let added = "% note\n";
    unsafe { edit(source, 0, 0, added.as_bytes()) };
    // The highlighting reads the session's text.
    let mut count = 0;
    let runs = unsafe { tl_source_highlights(source, 0, 6, &raw mut count) };
    assert_eq!(count, 3);
    unsafe { tl_source_free_runs(runs, count) };
    let saved = call(handle, "session_save", Some(json!({ "session": session })));
    assert_eq!(saved["ok"]["saved"], true);
    let disk = std::fs::read_to_string(dir.path().join("P/main.tex")).unwrap();
    assert_eq!(disk, format!("{added}{text}"));
    until(&events, |e| e["type"] == "saved" && e["session"] == session);
    // A reload is the disk's text, not an edit to save.
    unsafe { tl_source_reload(source, b"x".as_ptr(), 1) };
    let state = call(handle, "session_state", Some(json!({ "session": session })));
    assert_eq!(state["ok"]["documents"][0]["dirty"], false);
    unsafe { tl_source_free(source) };
    // Without blocking: the answer comes to the callback.
    let (answered, answers) = collector();
    let command = CString::new("session_state").unwrap();
    let args = CString::new(json!({ "session": session }).to_string()).unwrap();
    unsafe {
        tl_call_async(
            handle,
            command.as_ptr(),
            args.as_ptr(),
            Some(collect),
            context(&answered),
        );
    };
    let answer = until(&answers, |_| true);
    assert!(answer["ok"]["documents"].is_array());
    unsafe { tl_close(handle) };
}

/// `command` with `args` through `tl_call_async`, its answer going to `sink`.
fn call_async(handle: *const TlHandle, command: &str, args: Value, sink: &mpsc::Sender<Value>) {
    let command = CString::new(command).unwrap();
    let args = CString::new(args.to_string()).unwrap();
    unsafe {
        tl_call_async(
            handle,
            command.as_ptr(),
            args.as_ptr(),
            Some(collect),
            context(sink),
        );
    };
}

#[test]
fn a_session_takes_its_commands_in_the_order_they_were_sent_without_waiting() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(dir.path());
    let (sink, answers) = collector();
    call_async(
        handle,
        "session_open",
        json!({ "id": "P", "session": 7 }),
        &sink,
    );
    assert_eq!(until(&answers, |_| true)["ok"]["session"], 7);
    // The host numbers its sessions: a number open already is refused.
    let taken = call(
        handle,
        "session_open",
        Some(json!({ "id": "P", "session": 7 })),
    );
    assert_eq!(taken["status"], 409);
    for round in 0..50 {
        let last = round % 2 == 0;
        for auto in [!last, last, !last, last] {
            let args = json!({ "session": 7, "autoCompile": auto });
            call_async(handle, "session_set_options", args, &sink);
        }
        call_async(handle, "session_state", json!({ "session": 7 }), &sink);
        let state = until(&answers, |answer| answer["ok"]["autoCompile"].is_boolean());
        assert_eq!(state["ok"]["autoCompile"], last, "round {round}");
    }
    unsafe { tl_close(handle) };
}
