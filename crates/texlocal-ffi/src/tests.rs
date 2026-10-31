use std::cell::Cell;
use std::collections::BTreeMap;
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
    asked: Cell<u64>,
    _dir: tempfile::TempDir,
}

impl Core {
    fn open() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let (sender, events) = channel();
        let sender = Box::leak(Box::new(sender));
        let path = c(dir.path().to_str().unwrap());
        let ctx = (&raw const *sender).cast_mut().cast::<c_void>();
        let handle = unsafe { tl_open(path.as_ptr(), Some(collect), ctx) };
        assert!(!handle.is_null());
        Self {
            handle,
            events,
            asked: Cell::default(),
            _dir: dir,
        }
    }

    fn call(&self, command: &str, args: Value) -> Value {
        self.call_raw(None, Some(command), Some(&args.to_string()))
    }

    fn ask(&self, session: u64, command: &str, args: Value) -> Value {
        self.call_raw(Some(session), Some(command), Some(&args.to_string()))
    }

    fn call_raw(&self, session: Option<u64>, command: Option<&str>, args: Option<&str>) -> Value {
        let id = self.send(session, command, args);
        loop {
            let mut said = self.events.recv_timeout(Duration::from_secs(10)).unwrap();
            if said["type"] == "reply" && said["value"]["id"] == id {
                return said["value"]["answer"].take();
            }
        }
    }

    fn send(&self, session: Option<u64>, command: Option<&str>, args: Option<&str>) -> u64 {
        let id = self.asked.replace(self.asked.get() + 1);
        let (command, args) = (command.map(c), args.map(c));
        let pointer = |text: &Option<CString>| text.as_ref().map_or(ptr::null(), |t| t.as_ptr());
        let (command, args) = (pointer(&command), pointer(&args));
        match session {
            Some(session) => unsafe { tl_session_send(self.handle, id, session, command, args) },
            None => unsafe { tl_send(self.handle, id, command, args) },
        }
        id
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

fn source_text(source: *mut TlSource) -> String {
    let mut len = 0;
    let bytes = unsafe { tl_source_text(source, &raw mut len) };
    let text =
        String::from_utf8(unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec()).unwrap();
    unsafe { tl_source_free_text(bytes, len) };
    text
}

fn take(text: *mut c_char) -> Value {
    let value = serde_json::from_str(unsafe { CStr::from_ptr(text) }.to_str().unwrap()).unwrap();
    unsafe { tl_free(text) };
    value
}

fn answered(mut answer: Value) -> Value {
    assert_eq!(answer["type"], "ok", "{answer}");
    answer["value"].take()
}

fn refused(mut answer: Value) -> Value {
    assert_eq!(answer["type"], "error", "{answer}");
    answer["value"].take()
}

fn version(source: *mut TlSource) -> Option<u64> {
    let mut version = 0;
    unsafe { tl_source_version(source, &raw mut version) }.then_some(version)
}

#[test]
fn opening_needs_a_folder_and_a_listener() {
    let dir = c("/tmp");
    assert!(unsafe { tl_open(ptr::null(), Some(collect), ptr::null_mut()) }.is_null());
    assert!(unsafe { tl_open(dir.as_ptr(), None, ptr::null_mut()) }.is_null());
}

#[test]
fn each_command_answers_once_with_ok_or_an_error_kind() {
    let core = Core::open();
    core.call("CreateProject", json!({ "name": "P", "template": "blank" }));
    let (open, save) = (r#"{"id":"P","autoCompile":false}"#, r#"{"reporting":true}"#);
    let sent = [
        (None, Some("ReloadProjects"), Some("{}"), Some("ok")),
        (None, Some("nope"), Some("{}"), Some("notFound")),
        (
            None,
            Some("ReloadProjects"),
            Some("{not json"),
            Some("invalid"),
        ),
        (None, None, None, Some("invalid")),
        (
            Some(1),
            Some("ReloadProjects"),
            Some("{}"),
            Some("notFound"),
        ),
        (Some(1), Some("OpenProject"), Some(open), Some("ok")),
        (Some(1), Some("OpenProject"), Some(open), Some("conflict")),
        (Some(1), Some("Save"), Some(save), Some("ok")),
        (Some(2), Some("Save"), Some(save), Some("notFound")),
        (Some(1), None, None, Some("invalid")),
        (Some(1), Some("CloseProject"), Some("{}"), Some("ok")),
        (Some(1), Some("Save"), Some(save), None),
    ];
    let expected: Vec<(u64, Option<&str>)> = sent
        .map(|(session, command, args, kind)| (core.send(session, command, args), kind))
        .into();
    let mut replies = Vec::new();
    while replies.len() < expected.len() {
        let said = core.events.recv_timeout(Duration::from_secs(10)).unwrap();
        if said["type"] == "reply" {
            let answer = &said["value"]["answer"];
            let kind = if answer["type"] == "ok" {
                "ok"
            } else {
                answer["value"]["kind"].as_str().unwrap()
            };
            replies.push((said["value"]["id"].as_u64().unwrap(), kind.to_owned()));
        }
    }
    assert!(core.events.try_iter().all(|said| said["type"] != "reply"));
    replies.sort_unstable();
    let ids: Vec<u64> = replies.iter().map(|(id, _)| *id).collect();
    assert_eq!(ids, expected.iter().map(|(id, _)| *id).collect::<Vec<_>>());
    for ((id, kind), (_, expected)) in replies.iter().zip(&expected) {
        if let Some(expected) = expected {
            assert_eq!(kind, expected, "reply {id}");
        }
    }
    unsafe { tl_send(ptr::null(), 0, ptr::null(), ptr::null()) };
    unsafe { tl_session_send(ptr::null(), 0, 1, ptr::null(), ptr::null()) };
}

#[test]
fn a_session_document_is_edited_restored_saved_and_closed_through_the_abi() {
    let core = Core::open();
    core.call("CreateProject", json!({ "name": "P", "template": "blank" }));
    core.ask(7, "OpenProject", json!({ "id": "P", "autoCompile": false }));
    core.ask(7, "Open", json!({ "path": "main.tex" }));
    let path = c("main.tex");
    let source = unsafe { tl_session_source(core.handle, 7, path.as_ptr()) };
    assert!(!source.is_null());
    let (before, opened) = (source_text(source), version(source).unwrap());
    let note = "% note\n";
    let edit =
        || unsafe { tl_source_edit(source, 0, 0, note.as_ptr(), note.len(), ptr::null(), false) };
    assert_eq!(
        take(edit()),
        json!({ "type": "ok", "value": [] }),
        "an edit outside a snippet mirrors nothing"
    );
    let edited = format!("{note}{before}");
    assert_eq!(source_text(source), edited);
    unsafe { tl_source_restore(source, edited.as_ptr(), edited.len()) };
    assert_eq!(
        version(source),
        Some(opened + 1),
        "the same text changes nothing"
    );
    let text = "restored\n";
    unsafe { tl_source_restore(source, text.as_ptr(), text.len()) };
    assert_eq!(version(source), Some(opened + 2));
    assert!(unsafe { tl_source_editable(source) });
    assert_eq!(answered(core.ask(7, "CloseProject", json!({}))), true);
    let saved = std::fs::read_to_string(core._dir.path().join("P/main.tex")).unwrap();
    assert_eq!(saved, text);
    assert!(!unsafe { tl_source_editable(source) });
    assert_eq!(refused(take(edit()))["kind"], "conflict");
    assert_eq!(source_text(source), text);
    unsafe { tl_source_free(source) };
}

#[test]
fn session_events_reach_the_listener() {
    let core = Core::open();
    core.call(
        "CreateProject",
        json!({ "name": "P", "template": "article" }),
    );
    let open = r#"{"id":"P","autoCompile":false}"#;
    core.send(Some(1), Some("OpenProject"), Some(open));
    let found = (0..50)
        .filter_map(|_| core.events.recv_timeout(Duration::from_millis(200)).ok())
        .find(|said| said["type"] == "event" && said["value"]["event"]["type"] == "section");
    assert_eq!(found.unwrap()["value"]["session"], 1);
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
    assert_eq!(version(source), None);
    let command = c("ToggleComment");
    let args = c(r#"{"selections":[{"start":0,"length":0}]}"#);
    let answer = take(unsafe { tl_source_call(source, command.as_ptr(), args.as_ptr()) });
    assert!(answered(answer).is_array());
    let unknown = c("nope");
    let answer = take(unsafe { tl_source_call(source, unknown.as_ptr(), args.as_ptr()) });
    let refused = refused(answer);
    assert_eq!(refused["kind"], "invalid");
    let message = json!({ "id": "unknown_command", "args": {}, "text": "Unknown command" });
    assert_eq!(refused["message"], message);
    unsafe { tl_source_free(source) };
}

#[test]
fn syntax_commands_need_no_source() {
    let menus = c("ListMenus");
    let empty = c("{}");
    let answer = take(unsafe { tl_syntax_call(menus.as_ptr(), empty.as_ptr()) });
    assert!(answered(answer)["templates"].is_object());
    let refused = refused(take(unsafe { tl_syntax_call(ptr::null(), empty.as_ptr()) }));
    assert_eq!(refused["kind"], "invalid");
}

#[test]
fn a_panic_answers_an_error_and_a_new_source_survives_one() {
    let source = own(|| panic!("a broken editor"));
    assert_eq!(source_text(source), "");
    let answer = take(unsafe { answer_on(source, |_| panic!("a broken edit")) });
    assert_eq!(refused(answer)["kind"], "internal");
    let text = "kept";
    unsafe { tl_source_restore(source, text.as_ptr(), text.len()) };
    assert_eq!(source_text(source), text);
    unsafe { tl_source_free(source) };
}

#[test]
fn the_app_has_the_crates_version_from_one_place() {
    let config = include_str!("../../../apps/macos/Version.xcconfig");
    let version = concat!("MARKETING_VERSION = ", env!("CARGO_PKG_VERSION"));
    assert!(config.lines().any(|line| line == version), "{config}");
    let project = include_str!("../../../apps/macos/TeXLocal.xcodeproj/project.pbxproj");
    assert!(!project.contains("MARKETING_VERSION"));
}

type Signature = (String, Vec<String>);

fn words(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn enclosed(text: &str) -> (&str, &str) {
    let mut depth = 0;
    for (at, c) in text.char_indices() {
        match c {
            '(' => depth += 1,
            ')' if depth == 0 => return (&text[..at], &text[at + 1..]),
            ')' => depth -= 1,
            _ => {}
        }
    }
    panic!("no ) closes {text}")
}

fn listed(params: &str) -> Vec<&str> {
    let (mut list, mut depth, mut start) = (Vec::new(), 0, 0);
    for (at, c) in params.char_indices().chain([(params.len(), ',')]) {
        match c {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' if depth == 0 => {
                list.push(params[start..at].trim());
                start = at + 1;
            }
            _ => {}
        }
    }
    list.retain(|param| !param.is_empty());
    list
}

fn c_type(rust: &str) -> String {
    if let Some(pointee) = rust.strip_prefix("*const ") {
        return format!("const {} *", c_type(pointee));
    }
    if let Some(pointee) = rust.strip_prefix("*mut ") {
        return format!("{} *", c_type(pointee));
    }
    let callback = rust.strip_prefix("Option<extern \"C\" fn(");
    if let Some(params) = callback.and_then(|rest| rest.strip_suffix(")>")) {
        let params: Vec<String> = listed(params).into_iter().map(c_type).collect();
        return format!("void (*)({})", params.join(", "));
    }
    match rust {
        "bool" | "TlHandle" | "TlSource" => rust,
        "c_char" => "char",
        "c_void" => "void",
        "u8" => "uint8_t",
        "u32" => "uint32_t",
        "u64" => "uint64_t",
        "usize" => "size_t",
        "TextRange" => "TlRange",
        _ => panic!("{rust} has no C type"),
    }
    .into()
}

fn rust_functions(lib: &str) -> BTreeMap<String, Signature> {
    let lib = words(lib);
    let items = lib.split("#[unsafe(no_mangle)] pub unsafe extern \"C\" fn ");
    let function = |item: &str| {
        let (name, rest) = item.split_once('(').unwrap();
        let (params, rest) = enclosed(rest);
        let typed = |param: &str| c_type(param.split_once(": ").unwrap().1);
        let returns = rest.split_once('{').unwrap().0.trim().strip_prefix("-> ");
        let returns = returns.map_or("void".into(), c_type);
        (
            name.to_owned(),
            (returns, listed(params).into_iter().map(typed).collect()),
        )
    };
    items.skip(1).map(function).collect()
}

fn c_functions(header: &str) -> BTreeMap<String, Signature> {
    let code: Vec<&str> = header
        .lines()
        .filter(|line| !line.starts_with('#'))
        .collect();
    let code = words(&code.join(" ").replace("_Nullable", "").replace('*', " * "));
    let types = |params: &str| -> Vec<String> {
        let unnamed = |param: &str| {
            param
                .rsplit_once(' ')
                .map_or(param, |(ty, _)| ty)
                .to_owned()
        };
        listed(params).into_iter().map(unnamed).collect()
    };
    let (mut functions, mut pointers) = (BTreeMap::new(), BTreeMap::new());
    for declaration in code.split(';') {
        let Some((head, rest)) = declaration.split_once('(') else {
            continue;
        };
        let (inner, rest) = enclosed(rest);
        if let Some(returns) = head.trim().strip_prefix("typedef ") {
            let params = types(enclosed(rest.strip_prefix('(').unwrap()).0);
            let name = inner.replace('*', "").trim().to_owned();
            pointers.insert(name, format!("{returns} (*)({})", params.join(", ")));
        } else {
            let (returns, name) = head.trim().rsplit_once(' ').unwrap();
            functions.insert(name.to_owned(), (returns.to_owned(), types(inner)));
        }
    }
    for param in functions.values_mut().flat_map(|(_, params)| params) {
        if let Some(pointer) = pointers.get(param) {
            param.clone_from(pointer);
        }
    }
    functions
}

#[test]
fn the_header_declares_each_function_as_lib_rs_defines_it() {
    let lib = include_str!("lib.rs");
    let rust = rust_functions(lib);
    assert_eq!(rust.len(), lib.matches("#[unsafe(no_mangle)]").count());
    assert_eq!(c_functions(include_str!("../include/texlocal.h")), rust);
}
