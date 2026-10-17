// The C ABI's contract (include/texlocal.h), driven as a native host drives it.

use std::ffi::{CStr, CString, c_char, c_void};
use std::path::Path;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use texlocal_core::syntax::TextRange;
use texlocal_ffi::*;

type Handle = *mut TlHandle;
type Source = *mut TlSource;
type Callback = extern "C" fn(*mut c_void, *const c_char);

fn c(s: impl Into<Vec<u8>>) -> CString {
    CString::new(s).unwrap()
}

/// The JSON a call answered, freed; None for null.
unsafe fn take(out: *mut c_char) -> Option<Value> {
    if out.is_null() {
        return None;
    }
    let value = serde_json::from_slice(unsafe { CStr::from_ptr(out) }.to_bytes()).unwrap();
    unsafe { tl_free(out) };
    Some(value)
}

fn call_raw(h: Handle, command: &[u8], args: Option<&[u8]>) -> Value {
    let args = args.map(c);
    let args = args.as_ref().map_or(null(), |a| a.as_ptr());
    unsafe { take(tl_call(h, c(command).as_ptr(), args)) }.expect("tl_call answers")
}

fn call(h: Handle, command: &str, args: Value) -> Value {
    let args = args.to_string();
    call_raw(h, command.as_bytes(), Some(args.as_bytes()))
}

/// An error envelope's status.
fn status(answer: Value) -> Value {
    assert!(answer["error"].is_string(), "{answer}");
    answer["status"].clone()
}

/// A handle over `data` with one blank project, `P`.
fn open(data: &Path) -> Handle {
    let h = unsafe { tl_open(c(data.to_str().unwrap()).as_ptr()) };
    let project = json!({ "name": "P", "template": "blank" });
    assert_eq!(call(h, "create_project", project)["ok"]["id"], "P");
    h
}

/// Session `session` on `P`, with main.tex, holding `text`, open in it.
fn open_main(h: Handle, session: u64, text: &str) -> Source {
    let file = json!({ "id": "P", "path": "main.tex", "text": text });
    call(h, "write_file", file);
    let args = json!({ "id": "P", "session": session });
    assert_eq!(call(h, "session_open", args)["ok"]["session"], session);
    let args = json!({ "session": session, "path": "main.tex" });
    assert_eq!(
        call(h, "session_open_document", args),
        json!({ "ok": null })
    );
    unsafe { session_source(h, session, "main.tex") }
}

fn save(h: Handle, session: u64) -> Value {
    call(h, "session_save", json!({ "session": session }))
}

fn disk(data: &Path) -> String {
    std::fs::read_to_string(data.join("P/main.tex")).unwrap()
}

unsafe fn session_source(h: Handle, session: u64, path: &str) -> Source {
    unsafe { tl_session_source(h, session, c(path).as_ptr()) }
}

unsafe fn new_source(text: &str) -> Source {
    unsafe { tl_source_new(text.as_ptr(), text.len()) }
}

/// An edit as the editor makes it, having said it would: the mirror edits answered.
unsafe fn edit(source: Source, start: u32, length: u32, text: &[u8]) -> Option<Value> {
    let range = TextRange { start, length };
    let (bytes, len, range) = (text.as_ptr(), text.len(), &raw const range);
    unsafe {
        take(tl_source_edit(
            source, start, length, bytes, len, range, false,
        ))
    }
}

unsafe fn text_of(source: Source) -> String {
    let mut len = 0;
    let bytes = unsafe { tl_source_text(source, &raw mut len) };
    let text = String::from_utf8(unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec());
    unsafe { tl_source_free_text(bytes, len) };
    text.unwrap()
}

unsafe fn runs_of(source: Source, start: u32, length: u32) -> Vec<u32> {
    let mut count = usize::MAX;
    let runs = unsafe { tl_source_highlights(source, start, length, &raw mut count) };
    let copied = unsafe { std::slice::from_raw_parts(runs, count) }.to_vec();
    unsafe { tl_source_free_runs(runs, count) };
    copied
}

unsafe fn source_call(source: Source, command: &str, args: Value) -> Option<Value> {
    let (command, args) = (c(command), c(args.to_string()));
    unsafe { take(tl_source_call(source, command.as_ptr(), args.as_ptr())) }
}

unsafe fn syntax_call(command: &str, args: &str) -> Option<Value> {
    unsafe { take(tl_syntax_call(c(command).as_ptr(), c(args).as_ptr())) }
}

extern "C" fn collect(ctx: *mut c_void, json: *const c_char) {
    let sink = unsafe { &*ctx.cast::<Sender<Value>>() };
    let json = unsafe { CStr::from_ptr(json) }.to_bytes();
    let _ = sink.send(serde_json::from_slice(json).unwrap());
}

fn ctx<T>(value: &T) -> *mut c_void {
    (value as *const T).cast_mut().cast()
}

/// `command` through `tl_call_async`, its answer going to `sink`, if any.
fn call_async(h: Handle, command: &str, args: &[u8], sink: Option<&Sender<Value>>) {
    let (command, args) = (c(command), c(args));
    let done = sink.map_or((None, null_mut()), |sink| {
        (Some(collect as Callback), ctx(sink))
    });
    unsafe { tl_call_async(h, command.as_ptr(), args.as_ptr(), done.0, done.1) };
}

/// The first value collected that is `found`, within 10 s.
fn until(seen: &Receiver<Value>, found: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let value = seen.recv_timeout(left).expect("collected in time");
        if found(&value) {
            return value;
        }
    }
}

fn wait_for(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "{what}");
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn tl_call_answers_an_envelope_for_every_input() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    // Null arguments are `{}`.
    assert_eq!(call_raw(h, b"list_projects", None)["ok"][0]["id"], "P");
    let file = json!({ "id": "P", "path": "a.tex", "text": "x\0y" });
    call(h, "write_file", file);
    let read = call(h, "read_file", json!({ "id": "P", "path": "a.tex" }));
    assert_eq!(read["ok"]["text"], "x\0y");
    let root = call(h, "project_root", json!({ "id": "P" }));
    assert!(root["ok"].as_str().unwrap().ends_with('P'));
    let dest = dir.path().join("out.zip");
    let args = json!({ "id": "P", "dest": dest.to_str().unwrap() });
    assert_eq!(call(h, "export_zip", args), json!({ "ok": null }));
    assert!(dest.is_file());

    // Each mistake is an error with the core's status, never null or a crash.
    let mistakes = [
        ("read_file", Some(r#"{"id": "P", "path": "../x"}"#), 400),
        ("project_root", Some(r#"{"id": "../x"}"#), 400),
        ("import_files", Some(r#"{"id": "P", "paths": [42]}"#), 400),
        (
            "import_files",
            Some(r#"{"id": "P", "conflict": "merge"}"#),
            400,
        ),
        ("session_save", Some(r#"{"session": 9}"#), 404),
        ("list_projects", Some("{not json"), 400),
        ("nope", None, 404),
    ];
    for (command, args, code) in mistakes {
        let answer = call_raw(h, command.as_bytes(), args.map(str::as_bytes));
        assert_eq!(status(answer), code, "{command} {args:?}");
    }
    assert_eq!(status(call_raw(h, b"list_projects", Some(b"\xff"))), 400);
    assert_eq!(status(call_raw(h, b"\xff", None)), 400);
    assert_eq!(status(call_raw(null_mut(), b"list_projects", None)), 400);
    let no_command = unsafe { take(tl_call(h, null(), null())) };
    assert_eq!(status(no_command.unwrap()), 400);

    // The host names its library folder: there is no default.
    assert!(unsafe { tl_open(null()) }.is_null());
    unsafe {
        tl_free(null_mut());
        tl_close(h);
        tl_close(null_mut());
    }
}

#[test]
fn tl_call_async_answers_through_done_as_tl_call_would() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    let (sink, answers) = channel();
    let answer = |h, command, args: &str| {
        call_async(h, command, args.as_bytes(), Some(&sink));
        until(&answers, |_| true)
    };
    assert_eq!(answer(h, "list_projects", "{}")["ok"][0]["id"], "P");
    assert_eq!(status(answer(h, "nope", "{}")), 404);
    assert_eq!(status(answer(h, "session_save", r#"{"session": 9}"#)), 404);
    assert_eq!(status(answer(null_mut(), "list_projects", "{}")), 400);
    assert_eq!(status(answer(h, "list_projects", "{")), 400);

    // A null `done` runs the command for its effect alone.
    let file = json!({ "id": "P", "path": "b.tex", "text": "b" }).to_string();
    call_async(h, "write_file", file.as_bytes(), None);
    wait_for("the write ran", || dir.path().join("P/b.tex").is_file());
    unsafe { tl_close(h) };
}

#[test]
fn a_session_takes_its_async_commands_in_the_order_they_were_sent() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    let (sink, answers) = channel();
    let seven = br#"{"id": "P", "session": 7}"#;
    call_async(h, "session_open", seven, Some(&sink));
    assert_eq!(until(&answers, |_| true)["ok"]["session"], 7);
    // The host numbers its sessions: a number open already is refused.
    assert_eq!(status(call_raw(h, b"session_open", Some(seven))), 409);

    let (probe, probed) = channel();
    for round in 0..40 {
        let last = round % 2 == 0;
        for stop in [!last, last, !last, last] {
            let patch = json!({ "session": 7, "patch": { "stopOnFirstError": stop } });
            call_async(
                h,
                "session_set_settings",
                patch.to_string().as_bytes(),
                Some(&sink),
            );
        }
        let read = br#"{"session": 7, "patch": {}}"#;
        call_async(h, "session_set_settings", read, Some(&probe));
        let settings = until(&probed, |_| true);
        assert_eq!(settings["ok"]["stopOnFirstError"], last, "round {round}");
    }
    unsafe { tl_close(h) };
}

/// How often a listener was called, and whether a call to it is running.
#[derive(Default)]
struct Watch {
    calls: AtomicUsize,
    busy: AtomicBool,
}

extern "C" fn slow(ctx: *mut c_void, _json: *const c_char) {
    let watch = unsafe { &*ctx.cast::<Watch>() };
    watch.busy.store(true, SeqCst);
    std::thread::sleep(Duration::from_millis(100));
    watch.calls.fetch_add(1, SeqCst);
    watch.busy.store(false, SeqCst);
}

#[test]
fn the_listener_hears_a_sessions_events_until_it_is_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    let old = Box::new(Watch::default());
    unsafe { tl_set_listener(h, Some(slow), ctx(&*old)) };
    let source = open_main(h, 3, "x");
    unsafe { edit(source, 0, 0, b"a") };
    assert_eq!(save(h, 3)["ok"]["saved"], true);
    wait_for("the listener was called", || old.busy.load(SeqCst));
    // Replacing it waits out the call running, so the host may free its context.
    let (sink, events) = channel();
    unsafe { tl_set_listener(h, Some(collect), ctx(&sink)) };
    assert!(!old.busy.load(SeqCst));
    assert!(old.calls.load(SeqCst) > 0);
    drop(old);

    unsafe { edit(source, 0, 0, b"b") };
    save(h, 3);
    let saved = until(&events, |e| e["type"] == "saved");
    let expected = json!({ "type": "saved", "session": 3, "path": "main.tex" });
    assert_eq!(saved, expected);
    assert_eq!(disk(dir.path()), "bax");

    // Null removes it; no call follows tl_close.
    unsafe {
        tl_set_listener(h, None, null_mut());
        tl_set_listener(null(), Some(collect), ctx(&sink));
        tl_set_listener(h, Some(collect), ctx(&sink));
        tl_source_free(source);
        tl_close(h);
    }
    while events.try_recv().is_ok() {}
    std::thread::sleep(Duration::from_millis(50));
    assert!(events.try_recv().is_err(), "a call after tl_close");
}

#[test]
fn a_session_source_is_the_sessions_document() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    let source = open_main(h, 1, "\\x\n");
    unsafe {
        assert!(session_source(h, 1, "other.tex").is_null());
        assert!(session_source(h, 2, "main.tex").is_null());
        assert!(session_source(null_mut(), 1, "main.tex").is_null());
        assert!(tl_session_source(h, 1, null()).is_null());

        assert_eq!(text_of(source), "\\x\n");
        edit(source, 0, 0, b"% n\n");
        assert_eq!(
            runs_of(source, 0, 3),
            [0, 3, 5],
            "highlighted from its text"
        );
        let again = session_source(h, 1, "main.tex");
        assert_eq!(text_of(again), "% n\n\\x\n", "a second source shares it");
        tl_source_free(again);
        assert_eq!(save(h, 1)["ok"]["saved"], true);
        assert_eq!(disk(dir.path()), "% n\n\\x\n");

        // A reload is the disk's text, not an edit to save.
        tl_source_reload(source, b"r".as_ptr(), 1);
        assert_eq!(text_of(source), "r");
        assert_eq!(save(h, 1)["ok"]["saved"], true);
        assert_eq!(disk(dir.path()), "% n\n\\x\n");
        tl_source_free(source);
        tl_close(h);
    }
}

#[test]
fn a_session_source_starts_with_no_typing_state() {
    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    let key = |source, at: u32, text: &str| unsafe {
        let typed = json!({ "selection": { "start": at, "length": 0 }, "text": text });
        source_call(source, "type", typed).unwrap()
    };
    unsafe {
        let source = open_main(h, 1, "");
        assert_eq!(key(source, 0, "{")["edit"]["text"], "{}");
        edit(source, 0, 0, b"{}");
        let closed = key(source, 1, "}");
        assert_eq!(closed["selection"]["start"], 2, "steps over its closer");
        tl_source_free(source);
        // A bracket closed in one visit is only text in the next.
        let source = session_source(h, 1, "main.tex");
        assert_eq!(key(source, 1, "}")["selection"], Value::Null);
        tl_source_free(source);
        tl_close(h);
    }
}

#[test]
fn a_source_counts_utf16_units_and_keeps_every_byte() {
    unsafe {
        let source = new_source("é😀 \\emph{x}");
        // "é" is one unit, "😀" two.
        assert_eq!(runs_of(source, 0, 20), [4, 5, 0]);
        assert_eq!(edit(source, 3, 0, b"\n"), None);
        assert_eq!(text_of(source), "é😀\n \\emph{x}");
        let lines = [3, 4].map(|offset| tl_source_line_at(source, offset));
        assert_eq!(lines, [1, 2]);
        assert_eq!(
            [2, 99].map(|line| tl_source_line_start(source, line)),
            [4, 4]
        );

        // U+0000 is text like any other, going in and coming out.
        tl_source_reload(source, b"a\0\nb".as_ptr(), 4);
        assert_eq!(tl_source_line_count(source), 2);
        edit(source, 4, 0, b"\0c");
        assert_eq!(text_of(source), "a\0\nb\0c");
        // Bytes that aren't UTF-8 read as U+FFFD, one unit each, as Swift decodes them.
        edit(source, 1, 1, b"\xff\xfe");
        assert_eq!(text_of(source), "a\u{fffd}\u{fffd}\nb\0c");
        assert_eq!(tl_source_line_start(source, 2), 4);
        // An edit past the end is cut to the text.
        edit(source, 99, 99, b"!");
        assert_eq!(text_of(source), "a\u{fffd}\u{fffd}\nb\0c!");
        // A null text is empty, whatever its length.
        tl_source_edit(source, 0, 1, null(), 5, null(), false);
        assert_eq!(text_of(source), "\u{fffd}\u{fffd}\nb\0c!");
        tl_source_reload(source, null(), 3);
        assert_eq!(text_of(source), "");
        assert_eq!(tl_source_line_count(source), 1);
        tl_source_free(source);
        let empty = tl_source_new(null(), 7);
        assert_eq!(text_of(empty), "");
        tl_source_free(empty);
    }
}

/// A seeded run of edits, checked after each `burst` of them against the
/// text they should make and against a source made from that text afresh,
/// so a text, line table or highlighting an edit left stale shows.
fn edits_match_a_fresh_source(source: Source, steps: usize, burst: usize, mut seed: u64) {
    let pieces = ["a", "é", "😀", "\n", "\0", "\\x", "{", "}", "%", " ", "$"];
    let mut next = |below: usize| {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        (seed >> 33) as usize % below
    };
    let units = |text: &str| text.encode_utf16().count() as u32;
    let mut model = unsafe { text_of(source) };
    for step in 1..=steps {
        // Char boundaries, as UTF-16 offsets and byte offsets.
        let bounds = model.char_indices().map(|(i, _)| (units(&model[..i]), i));
        let bounds: Vec<_> = bounds.chain([(units(&model), model.len())]).collect();
        let from = next(bounds.len());
        let to = from + [0, 0, 1, 2, 3][next(5)].min(bounds.len() - 1 - from);
        let inserted: String = (0..next(3)).map(|_| pieces[next(pieces.len())]).collect();
        let (start, end) = (bounds[from], bounds[to]);
        unsafe { edit(source, start.0, end.0 - start.0, inserted.as_bytes()) };
        model.replace_range(start.1..end.1, &inserted);
        if step % burst != 0 {
            continue;
        }
        unsafe {
            assert_eq!(text_of(source), model);
            let lines = model.split('\n').count() as u32;
            assert_eq!(tl_source_line_count(source), lines);
            let mut start = 0;
            for (line, text) in (1..).zip(model.split('\n')) {
                assert_eq!(tl_source_line_start(source, line), start);
                let end = start + units(text);
                assert_eq!(tl_source_line_at(source, end), line);
                start = end + 1;
            }
            let fresh = new_source(&model);
            let (from, len) = (next(start as usize) as u32, next(12) as u32);
            assert_eq!(runs_of(source, from, len), runs_of(fresh, from, len));
            if step % (8 * burst) == 0 {
                assert_eq!(runs_of(source, 0, start), runs_of(fresh, 0, start));
            }
            tl_source_free(fresh);
        }
    }
}

#[test]
fn a_source_stays_in_step_through_many_edits() {
    let initial = "\\section{A}\nprose é $x$\n% c\n\n\\x{😀}";
    // Queries after each edit, as the editor makes them, and runs of edits
    // with none between.
    let source = unsafe { new_source(initial) };
    edits_match_a_fresh_source(source, 400, 1, 1);
    edits_match_a_fresh_source(source, 400, 9, 2);
    unsafe { tl_source_free(source) };

    let dir = tempfile::tempdir().unwrap();
    let h = open(dir.path());
    let source = open_main(h, 1, initial);
    edits_match_a_fresh_source(source, 150, 1, 3);
    edits_match_a_fresh_source(source, 150, 5, 4);
    save(h, 1);
    assert_eq!(disk(dir.path()), unsafe { text_of(source) });
    unsafe {
        tl_source_free(source);
        tl_close(h);
    }
}

#[test]
fn a_snippets_fields_mirror_what_is_typed_in_one() {
    unsafe {
        let source = new_source("\\begin{}\n\\end{}");
        let field = |start| json!({ "start": start, "length": 0, "index": 0 });
        let snippet = json!({ "fields": [field(7), field(14)], "at": 0 });
        source_call(source, "start_snippet", snippet);
        let mirror = json!([{ "start": 15, "length": 0, "text": "x" }]);
        assert_eq!(edit(source, 7, 0, b"x"), Some(mirror));
        // The mirror edits go in as mirroring, and answer none.
        assert!(tl_source_edit(source, 15, 0, b"x".as_ptr(), 1, null(), true).is_null());
        tl_source_select(source, 8, 0, false);
        assert_eq!(text_of(source), "\\begin{x}\n\\end{x}");
        // The snippet lasts while the selection is in its fields.
        let mirror = json!([{ "start": 16, "length": 1, "text": "xy" }]);
        assert_eq!(edit(source, 8, 0, b"y"), Some(mirror));
        tl_source_select(source, 0, 0, false);
        assert_eq!(edit(source, 0, 0, b"%"), None);
        tl_source_free(source);
    }
}

#[test]
fn source_and_syntax_commands_answer_json_or_null() {
    unsafe {
        let source = new_source("é x");
        let symbol = json!({ "command": "\\alpha", "selection": { "start": 0, "length": 1 } });
        let edit = json!({ "start": 0, "length": 1, "text": "$\\alpha$" });
        let answer = json!({ "edit": edit, "caret": 8, "fields": [] });
        assert_eq!(source_call(source, "insert_symbol", symbol), Some(answer));
        let maths = source_call(source, "math_at", json!({ "caret": 1 }));
        assert_eq!(maths, Some(Value::Null));
        assert_eq!(source_call(source, "unknown", json!({})), None);
        let (partner, args) = (c("partner"), c("{}"));
        assert!(tl_source_call(source, partner.as_ptr(), c("{").as_ptr()).is_null());
        assert!(tl_source_call(source, null(), args.as_ptr()).is_null());
        assert!(tl_source_call(source, partner.as_ptr(), null()).is_null());
        tl_source_free(source);

        // The commands that need no source: Windows asks its theme's colours so.
        let light = r#"{"theme": "overleaf", "dark": false, "background": [1, 1, 1, 1], "fill": [0, 0, 0, 0.08]}"#;
        let colors = syntax_call("theme_colors", light).unwrap();
        assert_eq!(colors.as_array().map(Vec::len), Some(9));
        assert_eq!(syntax_call("no such command", "{}"), None);
        let unknown = r#"{"theme": "solarized"}"#;
        assert_eq!(syntax_call("theme_colors", unknown), None);
        assert!(tl_syntax_call(null(), args.as_ptr()).is_null());
        assert!(tl_syntax_call(c("themes").as_ptr(), null()).is_null());
    }
}

#[test]
fn a_null_source_or_out_pointer_answers_nothing() {
    unsafe {
        let none: Source = null_mut();
        assert_eq!(edit(none, 0, 0, b"x"), None);
        tl_source_select(none, 0, 0, false);
        tl_source_reload(none, b"x".as_ptr(), 1);
        assert_eq!(text_of(none), "");
        assert_eq!(tl_source_line_at(none, 0), 0);
        assert_eq!(tl_source_line_start(none, 1), 0);
        assert_eq!(tl_source_line_count(none), 0);
        assert_eq!(runs_of(none, 0, 1), [] as [u32; 0]);
        assert_eq!(source_call(none, "partner", json!({})), None);
        tl_source_free(none);

        // What can't be freed without its length or count isn't handed out.
        let source = new_source("\\x");
        assert!(tl_source_text(source, null_mut()).is_null());
        assert!(tl_source_highlights(source, 0, 9, null_mut()).is_null());
        tl_source_free_text(null_mut(), 0);
        tl_source_free_runs(null_mut(), 0);
        tl_source_free(source);
    }
}
