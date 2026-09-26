// Round trips through the C ABI exactly as a native host drives it.

use std::ffi::{CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;

use serde_json::{json, Value};
use texlocal_ffi::{tl_call, tl_close, tl_free, tl_open, TlHandle};

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
