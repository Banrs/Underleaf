// Round trips through the C ABI exactly as a native host drives it.

use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;

use serde_json::{json, Value};
use texlocal_ffi::{
    tl_call, tl_close, tl_free, tl_open, tl_source_call, tl_source_edit, tl_source_free,
    tl_source_free_runs, tl_source_highlights, tl_source_line_at, tl_source_line_count,
    tl_source_line_start, tl_source_new, TlHandle, TlSource,
};

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
        let value = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
        tl_free(out);
        value
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

fn strings<const N: usize>(paths: [PathBuf; N]) -> [String; N] {
    paths.map(|p| p.to_str().unwrap().to_owned())
}

fn saved(out: &Value) -> Vec<String> {
    let mut saved: Vec<String> = serde_json::from_value(out["ok"]["saved"].clone()).unwrap();
    saved.sort();
    saved
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

    call(
        handle,
        "write_file",
        Some(json!({ "id": "P", "path": "main.tex", "text": "\\section{Intro}\nHello world" })),
    );
    assert_eq!(
        call(
            handle,
            "analyze_project",
            Some(json!({ "id": "P", "file": "main.tex" }))
        )["ok"],
        json!({ "outline": [{ "depth": 2, "title": "Intro", "line": 1, "file": "main.tex" }], "words": 3, "lines": 2 })
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

    let raw = call(
        handle,
        "raw_path",
        Some(json!({ "id": "P", "path": "img/a.png" })),
    );
    assert!(raw["ok"].as_str().unwrap().ends_with("a.png"));
    let escape = call(
        handle,
        "raw_path",
        Some(json!({ "id": "P", "path": "../../x" })),
    );
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

    let dir = tempfile::tempdir().unwrap();
    let handle = open(dir.path());
    assert_eq!(
        call_raw(handle, "list_projects", Some("{not json"))["status"],
        400
    );
    unsafe {
        tl_free(ptr::null_mut());
        tl_close(handle);
        tl_close(ptr::null_mut());
    }
}

#[test]
fn dropped_files_and_folders_import_into_the_project() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(&dir.path().join("data"));

    let drop = dir.path().join("drop");
    std::fs::create_dir_all(drop.join("figs/sub")).unwrap();
    std::fs::write(drop.join("figs/a.png"), b"a").unwrap();
    std::fs::write(drop.join("figs/sub/b.png"), b"b").unwrap();
    std::fs::write(drop.join("notes.tex"), b"n").unwrap();
    let paths = strings([drop.join("figs"), drop.join("notes.tex")]);

    let out = call(
        handle,
        "import_files",
        Some(json!({ "id": "P", "dir": "in", "paths": paths })),
    );
    assert_eq!(
        saved(&out),
        ["in/figs/a.png", "in/figs/sub/b.png", "in/notes.tex"]
    );
    assert_eq!(
        std::fs::read(dir.path().join("data/P/in/figs/sub/b.png")).unwrap(),
        b"b"
    );

    // A batch that would collide fails before anything is written.
    let twice = strings([drop.join("notes.tex"), drop.join("notes.tex")]);
    let refused = call(
        handle,
        "import_files",
        Some(json!({ "id": "P", "dir": "again", "paths": twice })),
    );
    assert_eq!(refused["status"], 400);
    assert!(!dir.path().join("data/P/again").exists());

    // A path that is not a string is the caller's mistake, not an I/O error.
    let malformed = call(
        handle,
        "import_files",
        Some(json!({ "id": "P", "paths": [42] })),
    );
    assert_eq!(malformed["status"], 400);

    unsafe { tl_close(handle) };
}

#[test]
fn a_drop_onto_existing_files_asks_first_and_can_keep_both() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(&dir.path().join("data"));

    let drop = dir.path().join("drop");
    std::fs::create_dir_all(drop.join("figs/.git")).unwrap();
    std::fs::write(drop.join("figs/.git/HEAD"), b"ref").unwrap();
    std::fs::write(drop.join("figs/.DS_Store"), b"x").unwrap();
    std::fs::write(drop.join("figs/a.png"), b"a").unwrap();
    std::fs::write(drop.join("main.tex"), b"new").unwrap();
    let paths = strings([drop.join("figs"), drop.join("main.tex")]);
    let args = |conflict: Value| json!({ "id": "P", "paths": paths, "conflict": conflict });

    // Without an answer nothing is written; the clash is reported.
    let asked = call(handle, "import_files", Some(args(Value::Null)));
    assert_eq!(
        asked["ok"],
        json!({ "saved": [], "existing": [{ "path": "main.tex", "keepBoth": "main 2.tex" }] })
    );
    let main = dir.path().join("data/P/main.tex");
    let original = std::fs::read(&main).unwrap();

    let kept = call(handle, "import_files", Some(args(json!("keepBoth"))));
    // Hidden files inside a dropped folder stay behind.
    assert_eq!(saved(&kept), ["figs/a.png", "main 2.tex"]);
    assert_eq!(std::fs::read(&main).unwrap(), original);
    assert_eq!(
        std::fs::read(dir.path().join("data/P/main 2.tex")).unwrap(),
        b"new"
    );

    let bad = call(handle, "import_files", Some(args(json!("merge"))));
    assert_eq!(bad["status"], 400);

    unsafe { tl_close(handle) };
}

#[test]
fn file_open_imports_a_chosen_file_as_a_new_project() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open(&dir.path().join("data"));
    let tex = dir.path().join("essay.tex");
    std::fs::write(&tex, "\\documentclass{article}").unwrap();
    let [src] = strings([tex]);
    let out = call(handle, "import_project", Some(json!({ "src": src })));
    assert_eq!(out["ok"]["id"], "essay");
    assert_eq!(out["ok"]["mainFile"], "essay.tex");
    unsafe { tl_close(handle) };
}

#[cfg(unix)]
#[test]
fn a_dropped_link_imports_what_it_points_at_but_links_inside_a_folder_do_not() {
    let dir = tempfile::tempdir().unwrap();
    let handle = open_with_project(&dir.path().join("data"));

    let elsewhere = dir.path().join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    std::fs::write(elsewhere.join("plot.png"), b"p").unwrap();
    let drop = dir.path().join("drop");
    std::fs::create_dir_all(drop.join("figs")).unwrap();
    std::os::unix::fs::symlink(elsewhere.join("plot.png"), drop.join("plot-link.png")).unwrap();
    std::os::unix::fs::symlink(elsewhere.join("plot.png"), drop.join("figs/inner.png")).unwrap();
    std::fs::write(drop.join("figs/real.png"), b"r").unwrap();
    let paths = strings([drop.join("plot-link.png"), drop.join("figs")]);

    let out = call(
        handle,
        "import_files",
        Some(json!({ "id": "P", "dir": "", "paths": paths })),
    );
    assert_eq!(saved(&out), ["figs/real.png", "plot-link.png"]);
    assert_eq!(
        std::fs::read(dir.path().join("data/P/plot-link.png")).unwrap(),
        b"p"
    );

    unsafe { tl_close(handle) };
}

#[test]
fn the_source_mirror_round_trips_through_the_c_abi() {
    let c = |s: &str| CString::new(s).unwrap();
    unsafe {
        let text = "é \\emph{x}";
        let source = tl_source_new(text.as_ptr(), text.len());
        // Offsets count UTF-16 units: "é " is two.
        tl_source_edit(source, 2, 0, "\n".as_ptr(), 1);
        assert_eq!(tl_source_line_at(source, 3), 2);
        let mut count = 0;
        let runs = tl_source_highlights(source, 0, 20, &mut count);
        assert_eq!(std::slice::from_raw_parts(runs, count), [3, 5, 0]);
        tl_source_free_runs(runs, count);
        let call_on = |source: *mut TlSource, command: &str| {
            let out = tl_source_call(source, c(command).as_ptr(), c("{}").as_ptr());
            let value: Value = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
            tl_free(out);
            Some(value)
        };
        let call = |command: &str, args: Value| {
            let out = tl_source_call(source, c(command).as_ptr(), c(&args.to_string()).as_ptr());
            if out.is_null() {
                return None;
            }
            let value: Value = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
            tl_free(out);
            Some(value)
        };
        assert_eq!(call("text", json!({})), Some(json!("é \n\\emph{x}")));
        let symbol = call(
            "insert_symbol",
            json!({ "command": "\\alpha", "selection": { "start": 0, "length": 1 } }),
        );
        assert_eq!(
            symbol,
            Some(
                json!({ "edit": { "start": 0, "length": 1, "text": "$\\alpha$" }, "caret": 8, "fields": [] })
            )
        );
        let maths = call("math_at", json!({ "caret": 1 }));
        assert_eq!(maths, Some(Value::Null), "é isn't maths");
        assert_eq!(call("unknown", json!({})), None);
        tl_source_free(source);

        // A U+0000 is text like any other: it doesn't end the mirror's copy.
        let text = "a\0\nb";
        let source = tl_source_new(text.as_ptr(), text.len());
        assert_eq!(tl_source_line_count(source), 2);
        tl_source_edit(source, 4, 0, "\0c".as_ptr(), 2);
        assert_eq!(call_on(source, "text"), Some(json!("a\u{0}\nb\u{0}c")));
        tl_source_free(source);
    }
}

#[test]
fn the_source_mirror_answers_null_and_garbage_without_unwinding() {
    let c = |s: &str| CString::new(s).unwrap();
    unsafe {
        let none: *mut TlSource = ptr::null_mut();
        tl_source_edit(none, 0, 0, "x".as_ptr(), 1);
        assert_eq!(tl_source_line_at(none, 0), 0);
        assert_eq!(tl_source_line_start(none, 1), 0);
        assert_eq!(tl_source_line_count(none), 0);
        let mut count = 7;
        let runs = tl_source_highlights(none, 0, 1, &mut count);
        assert_eq!(count, 0, "no runs");
        tl_source_free_runs(runs, count);
        assert!(tl_source_call(none, c("text").as_ptr(), c("{}").as_ptr()).is_null());
        tl_source_free(none);

        let source = tl_source_new(ptr::null(), 0);
        assert!(!source.is_null());
        assert!(tl_source_call(source, c("text").as_ptr(), c("{not json").as_ptr()).is_null());
        assert!(tl_source_call(source, ptr::null(), c("{}").as_ptr()).is_null());
        assert!(tl_source_call(source, c("text").as_ptr(), ptr::null()).is_null());
        // Out-of-range offsets are cut to the text.
        tl_source_edit(source, 99, 99, "ab".as_ptr(), 2);
        assert_eq!(tl_source_line_start(source, 99), 0);
        let runs = tl_source_highlights(source, 99, 99, &mut count);
        assert_eq!(count, 0);
        tl_source_free_runs(runs, count);
        // A null count is no place to write: the runs still come back.
        let runs = tl_source_highlights(source, 0, 9, ptr::null_mut());
        tl_source_free_runs(runs, 0);

        // Bytes that aren't UTF-8 read as U+FFFD, as Swift decodes them: the
        // edit still lands, keeping the mirror in step with the editor.
        tl_source_edit(source, 1, 0, b"\xff\n".as_ptr(), 2);
        let out = tl_source_call(source, c("text").as_ptr(), c("{}").as_ptr());
        let text: Value = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
        tl_free(out);
        assert_eq!(text, json!("a\u{fffd}\nb"));
        assert_eq!(tl_source_line_count(source), 2);
        tl_source_free(source);
    }
}
