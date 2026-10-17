// The editor's calls for each key, over a long document, timed: run with
// `cargo test --release -p texlocal-ffi --test typing_speed -- --ignored --nocapture`.

use std::ffi::{CStr, CString};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use texlocal_core::syntax::TextRange;
use texlocal_ffi::{
    TlSource, tl_free, tl_source_call, tl_source_edit, tl_source_free, tl_source_free_runs,
    tl_source_highlights, tl_source_line_at, tl_source_line_count, tl_source_line_start,
    tl_source_new, tl_source_select,
};

unsafe fn source_call(source: *mut TlSource, command: &str, args: Value) -> Value {
    let command = CString::new(command).unwrap();
    let args = CString::new(args.to_string()).unwrap();
    let out = unsafe { tl_source_call(source, command.as_ptr(), args.as_ptr()) };
    let value = serde_json::from_str(unsafe { CStr::from_ptr(out) }.to_str().unwrap()).unwrap();
    unsafe { tl_free(out) };
    value
}

/// Each key as SourceTextView sends it: `type`, the storage's edit, the
/// selection after it, and the colours of the edited line.
#[test]
#[ignore]
fn typing_speed() {
    let paragraph = "\\section{Results}\nThe value $x^2 + \\alpha$ is \\textbf{bold} and \\cite{knuth84}.\n% a comment\n\\begin{equation}\n  E = mc^2\n\\end{equation}\nPlain prose with words in it, several of them.\n\n";
    let text = paragraph.repeat(3000);
    let source = unsafe { tl_source_new(text.as_ptr(), text.len()) };
    let mut caret = (text.encode_utf16().count() / 2) as u32;
    let typed = "Some words {in} braces, more prose here. ".repeat(50);
    let keys = typed.chars().count();
    let (mut edit_only, mut edit_and_select) = (Duration::ZERO, Duration::ZERO);
    let start = Instant::now();
    for key in typed.chars() {
        let key = key.to_string();
        let selection = json!({ "start": caret, "length": 0 });
        let args = json!({ "selection": selection, "text": key });
        let stroke = unsafe { source_call(source, "type", args) };
        let edit = &stroke["edit"];
        let (at, length, put) = if !edit.is_null() {
            let unit = |key: &str| edit[key].as_u64().unwrap() as u32;
            (
                unit("start"),
                unit("length"),
                edit["text"].as_str().unwrap().to_owned(),
            )
        } else if !stroke["selection"].is_null() {
            // A closer stepped over.
            caret = stroke["selection"]["start"].as_u64().unwrap() as u32;
            continue;
        } else {
            (caret, 0, key)
        };
        let changing = TextRange { start: at, length };
        let (bytes, len, changing) = (put.as_ptr(), put.len(), &raw const changing);
        let timed = Instant::now();
        let mirror = unsafe { tl_source_edit(source, at, length, bytes, len, changing, false) };
        edit_only += timed.elapsed();
        assert!(mirror.is_null());
        caret = at + 1;
        unsafe { tl_source_select(source, caret, 0, false) };
        edit_and_select += timed.elapsed();
        unsafe {
            let line = tl_source_line_at(source, caret);
            let from = tl_source_line_start(source, line);
            let to = tl_source_line_start(source, line + 1);
            let mut count = 0;
            let runs = tl_source_highlights(source, from, to.saturating_sub(from), &raw mut count);
            tl_source_free_runs(runs, count);
            tl_source_line_count(source);
        }
    }
    let per_key = |time: Duration| time.as_secs_f64() * 1e6 / keys as f64;
    eprintln!(
        "{keys} keys: {:.1} µs a key, of which tl_source_edit and tl_source_select {:.1} µs, tl_source_edit {:.1} µs",
        per_key(start.elapsed()),
        per_key(edit_and_select),
        per_key(edit_only)
    );
    unsafe { tl_source_free(source) };
}
