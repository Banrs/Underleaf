// Round trips through the C ABI exactly as a native host drives it.

use std::ffi::{CStr, CString};
use std::ptr;

use serde_json::{json, Value};
use texlocal_ffi::{tl_call, tl_close, tl_free, tl_open, TlHandle};

fn call(handle: *const TlHandle, command: &str, args: Option<Value>) -> Value {
    let command = CString::new(command).unwrap();
    let args = args.map(|a| CString::new(a.to_string()).unwrap());
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

#[test]
fn commands_round_trip_through_the_c_abi() {
    let dir = tempfile::tempdir().unwrap();
    let path = CString::new(dir.path().to_str().unwrap()).unwrap();
    let handle = unsafe { tl_open(path.as_ptr()) };
    assert!(!handle.is_null());

    let created = call(
        handle,
        "create_project",
        Some(json!({ "name": "P", "template": "blank" })),
    );
    assert_eq!(created["ok"]["id"], "P");
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
    let path = CString::new(dir.path().to_str().unwrap()).unwrap();
    let handle = unsafe { tl_open(path.as_ptr()) };
    call(
        handle,
        "create_project",
        Some(json!({ "name": "P", "template": "blank" })),
    );

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
    let path = CString::new(dir.path().to_str().unwrap()).unwrap();
    let handle = unsafe { tl_open(path.as_ptr()) };
    let command = CString::new("list_projects").unwrap();
    let args = CString::new("{not json").unwrap();
    unsafe {
        let out = tl_call(handle, command.as_ptr(), args.as_ptr());
        let value: Value = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
        tl_free(out);
        assert_eq!(value["status"], 400);
        tl_free(ptr::null_mut());
        tl_close(handle);
        tl_close(ptr::null_mut());
    }
}
