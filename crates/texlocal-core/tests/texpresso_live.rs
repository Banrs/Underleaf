//! Live preview end to end with a real TeXpresso, through a project session as the hosts
//! drive it: the editor's edits go to the session's documents, and what TeXpresso shows
//! comes back as events. `TEXLOCAL_TEXPRESSO` names the program, and TeX Live must be on
//! the PATH. Headless, and everything it writes is in a temporary folder.
//!
//! cargo test -p texlocal-core --test texpresso_live -- --ignored --nocapture

use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use texlocal_core::service::Service;
use texlocal_core::session::{Document, Sessions};

#[test]
#[ignore = "needs TeXpresso (TEXLOCAL_TEXPRESSO) and TeX Live"]
fn live_preview_follows_unsaved_edits() {
    if std::env::var_os("TEXLOCAL_TEXPRESSO").is_none_or(|path| path.is_empty()) {
        eprintln!("TEXLOCAL_TEXPRESSO is not set: nothing to check.");
        return;
    }
    let scratch = tempfile::tempdir().unwrap();
    // SAFETY: before this test starts a thread; it is its binary's only test.
    unsafe {
        std::env::set_var("SDL_VIDEODRIVER", "dummy");
        for (key, dir) in [("XDG_CACHE_HOME", "cache"), ("TEXMFVAR", "texmf-var")] {
            std::env::set_var(key, scratch.path().join(dir));
        }
        std::env::set_var("TEXMFCONFIG", scratch.path().join("texmf-config"));
    }
    let mut runtime = tokio::runtime::Builder::new_multi_thread();
    let runtime = runtime.enable_all().build().unwrap();
    runtime.block_on(run(&scratch.path().join("projects")));
}

/// The longest any one thing may take.
const PATIENCE: Duration = Duration::from_secs(90);

/// A project's sessions, as a host has them, and every event they sent.
struct Client {
    sessions: Sessions,
    events: Arc<Mutex<Vec<Value>>>,
    id: String,
    /// The last session's number: a host numbers its own.
    opened: AtomicU64,
}

impl Client {
    async fn open(&self) -> u64 {
        let session = self.opened.fetch_add(1, Ordering::Relaxed) + 1;
        let args = json!({ "id": self.id, "session": session });
        let answer = self.sessions.call("session_open", &args).await;
        answer.unwrap()["session"].as_u64().unwrap()
    }

    /// `session_<command>` in `session`.
    async fn ask(&self, session: u64, command: &str, mut args: Value) -> Value {
        args["session"] = json!(session);
        let command = format!("session_{command}");
        let answer = self.sessions.call(&command, &args).await;
        answer.unwrap_or_else(|err| panic!("{command}: {} {}", err.status, err.message))
    }

    /// The document at `path` the editor of `session` edits.
    async fn document(&self, session: u64, path: &str) -> Document {
        let args = json!({ "path": path });
        self.ask(session, "open_document", args).await;
        self.sessions.document(session, path).unwrap()
    }

    /// Starts the preview of `session` with its Live Preview Log shown, as a host does
    /// with the log open: each `live` event then carries the log.
    async fn start(&self, session: u64) {
        let shown = json!({ "shown": true });
        self.ask(session, "live_log", shown).await;
        let started = self.ask(session, "live_start", json!({})).await;
        assert_eq!(started["phase"], "running", "{started}");
    }

    fn count(&self) -> usize {
        self.events.lock().unwrap().len()
    }

    /// The first event from `from` on of `session` and `kind` that `wanted` takes, once
    /// it comes; `from` moves past it.
    async fn event(
        &self,
        from: &mut usize,
        session: u64,
        kind: &str,
        wanted: impl Fn(&Value) -> bool,
    ) -> Value {
        let began = Instant::now();
        loop {
            {
                let events = self.events.lock().unwrap();
                let mut later = events.iter().enumerate().skip(*from);
                let ours = |e: &Value| e["session"] == session && e["type"] == kind && wanted(e);
                if let Some((at, event)) = later.find(|(_, event)| ours(event)) {
                    *from = at + 1;
                    return event.clone();
                }
            }
            assert!(began.elapsed() < PATIENCE, "no {kind} event wanted");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    /// Waits for the Live Preview Log of a running preview to have a line that starts with
    /// `text`, as TeX writes its lines, across any restart of the session's own. Until TeX
    /// has said something the log has TeXpresso's stderr too, which may echo what it was sent.
    async fn shows(&self, session: u64, text: &str) {
        let began = Instant::now();
        loop {
            // The preview as the last `live` event left it.
            let mut lives = self.since(0, "live").into_iter();
            let live = lives.rfind(|e| e["session"] == session).unwrap_or_default();
            let log = live["log"].as_str().unwrap_or_default();
            if live["phase"] == "running" && log.lines().any(|line| line.starts_with(text)) {
                break;
            }
            assert!(began.elapsed() < PATIENCE, "no {text} in {live}");
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        println!("{text}: {} ms", began.elapsed().as_millis());
    }

    /// Where the events stand once none has come for half a second.
    async fn settled(&self) -> usize {
        let mut seen = usize::MAX;
        while self.count() != seen {
            seen = self.count();
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        seen
    }

    /// The events of `kind` from `from` on.
    fn since(&self, from: usize, kind: &str) -> Vec<Value> {
        let events = self.events.lock().unwrap();
        events[from..].iter().filter(|e| e["type"] == kind).cloned().collect()
    }
}

/// Types `text` over the document's own, as one edit of the range that differs, in
/// UTF-16 units as the editor counts. The texts here differ by whole characters.
fn retype(document: &Document, text: &str) {
    let old: Vec<u16> = document.with(|source| source.text().encode_utf16().collect());
    let new: Vec<u16> = text.encode_utf16().collect();
    let start = old.iter().zip(&new).take_while(|(a, b)| a == b).count();
    let (old, new) = (&old[start..], &new[start..]);
    let end = old.iter().rev().zip(new.iter().rev()).take_while(|(a, b)| a == b).count();
    let inserted = String::from_utf16(&new[..new.len() - end]).unwrap();
    document.edit(start as u32, (old.len() - end) as u32, &inserted);
}

fn is_pdf(path: &Value) {
    let path = Path::new(path.as_str().unwrap());
    let bytes = std::fs::read(path).unwrap();
    assert!(bytes.starts_with(b"%PDF-"), "{}", path.display());
}

/// UTF-16 units before `what` in `text`, as the editor counts.
fn units_to(text: &str, what: &str) -> u32 {
    text[..text.find(what).unwrap()].encode_utf16().count() as u32
}

async fn run(library: &Path) {
    std::fs::create_dir_all(library).unwrap();
    let service = Arc::new(Service::new(library.to_path_buf()));
    let args = json!({ "name": "TeXpresso check", "template": "blank" });
    let project = service.call("create_project", &args).await.unwrap();
    let id = project["id"].as_str().unwrap().to_owned();
    let root = service.project_root(&id).unwrap();
    let sessions = Sessions::new(Arc::clone(&service));
    let events = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&events);
    let listener = move |event: &Value| sink.lock().unwrap().push(event.clone());
    sessions.set_listener(Some(Box::new(listener)));
    let opened = AtomicU64::new(0);
    let c = Client { sessions, events, id, opened };
    let main = "\\documentclass{article}\n\\begin{document}\n\\typeout{UL_MAIN_INITIAL}\nHello café. $x^2+y^2=z^2$\n\\input{section.tex}\n\\end{document}\n";
    let section = "\\typeout{UL_SECTION_INITIAL}\nIncluded text.\n";
    let write = |path: &str, text: &str| {
        let path = root.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    };
    write("main.tex", main);
    write("section.tex", section);
    let xelatex = json!({ "engine": "xelatex" });
    texlocal_core::settings::write_settings(&root, &xelatex).unwrap();

    // As the Mac app starts it: the pages in view first, the document shown in its
    // pane. The main file and the file it includes.
    let a = c.open().await;
    let main_doc = c.document(a, "main.tex").await;
    c.ask(a, "live_view", json!({ "first": 1, "last": 1 })).await;
    c.start(a).await;
    c.shows(a, "UL_SECTION_INITIAL").await;

    // Unsaved edits: in Unicode to the main file, to an included one opened while it
    // runs, an error, and recovery without a restart.
    let unicode = main.replace("UL_MAIN_INITIAL", "UL_MAIN_UNSAVED");
    let unicode = unicode.replace("Hello café.", "Unsaved café — naïve.");
    retype(&main_doc, &unicode);
    c.shows(a, "UL_MAIN_UNSAVED").await;
    let section_doc = c.document(a, "section.tex").await;
    let unsaved = section.replace("UL_SECTION_INITIAL", "UL_SECTION_UNSAVED");
    retype(&section_doc, &unsaved);
    c.shows(a, "UL_SECTION_UNSAVED").await;
    let broken = "\\UnderleafInvalidCommand\nUnsaved café";
    retype(&main_doc, &unicode.replace("Unsaved café", broken));
    c.shows(a, "! Undefined control sequence").await;
    let recovered = unicode.replace("UL_MAIN_UNSAVED", "UL_MAIN_RECOVERED");
    retype(&main_doc, &recovered);
    c.shows(a, "UL_MAIN_RECOVERED").await;

    // Each half-typed text reaches the engine, which must survive it.
    let end = recovered.find("\\end{document}").unwrap();
    let words = |with: &str| recovered.replace("Unsaved café", with);
    let incomplete = [
        recovered.replace("$x^2+y^2=z^2$", "$x^2+y^2=z^2"),
        recovered.replace("$x^2+y^2=z^2$", "\\[x^2+y^2=z^2"),
        format!("{}\\", &recovered[..end]),
        words("\\fra Unsaved café"),
        words("\\textbf{Unsaved café"),
        words("\\begin{itemize}\\item Unsaved café"),
        "\\documentclass{artic".to_owned(),
    ];
    let typed = |index: usize| format!("UL_TYPING_RECOVERED_{index}");
    for (index, text) in incomplete.iter().enumerate() {
        retype(&main_doc, text);
        tokio::time::sleep(Duration::from_millis(700)).await;
        let again = recovered.replace("UL_MAIN_RECOVERED", &typed(index));
        retype(&main_doc, &again);
        c.shows(a, &typed(index)).await;
    }

    // A build beside the preview.
    let mut from = c.count();
    c.ask(a, "compile", json!({})).await;
    let built = c.event(&mut from, a, "build_finished", |_| true).await;
    let result = &built["result"];
    assert_eq!(result["ok"], true, "{}", result["log"]);
    is_pdf(&result["pdf"]);
    let after_build = section.replace("UL_SECTION_INITIAL", "UL_AFTER_BUILD");
    retype(&section_doc, &after_build);
    c.shows(a, "UL_AFTER_BUILD").await;

    // A main file in a folder, its inputs from there: the session starts the preview
    // again for it.
    write("nested/main.tex", &main.replace("UL_MAIN_INITIAL", "UL_NESTED_MAIN"));
    let nested = section.replace("UL_SECTION_INITIAL", "UL_NESTED_SECTION");
    write("nested/section.tex", &nested);
    let nested = json!({ "patch": { "mainFile": "nested/main.tex" } });
    c.ask(a, "set_settings", nested).await;
    c.shows(a, "UL_NESTED_SECTION").await;
    let nested_doc = c.document(a, "nested/section.tex").await;
    retype(&nested_doc, "\\typeout{UL_NESTED_UNSAVED}\nNested live edit.\n");
    c.shows(a, "UL_NESTED_UNSAVED").await;

    // The pages in view as PDFs of their own as they change, and the whole document when
    // typing pauses. Only a build with Underleaf's patch (tools/texpresso) sends them.
    let main_again = json!({ "patch": { "mainFile": "main.tex" } });
    c.ask(a, "set_settings", main_again).await;
    c.shows(a, &typed(incomplete.len() - 1)).await;
    let paged = "\\documentclass{article}\n\\begin{document}\nPage one café.\n\\newpage\nPage two.\n\\end{document}\n";
    let paging = c.count();
    retype(&main_doc, paged);
    let mut from = paging;
    let whole = |e: &Value| e["pages"] == 2 && e["complete"] == true;
    let whole = c.event(&mut from, a, "live_document", whole).await;
    is_pdf(&whole["path"]);
    let synctex = Path::new(whole["path"].as_str().unwrap()).with_extension("synctex");
    assert!(!std::fs::read(synctex).unwrap().is_empty());

    // An offset in UTF-16 units, past the é that is two bytes to TeXpresso.
    let mut from = c.settled().await;
    let began = Instant::now();
    main_doc.edit(units_to(paged, "two"), 0, "number ");
    let second = |e: &Value| e["page"] == 1;
    let page = c.event(&mut from, a, "live_page", second).await;
    is_pdf(&page["path"]);
    println!("A key on the page in view: {} ms", began.elapsed().as_millis());
    let complete = |e: &Value| e["complete"] == true;
    let after = c.event(&mut from, a, "live_document", complete).await;
    assert_eq!(after["changed"], json!([[1, 1]]));
    let pages = c.since(paging, "live_page");
    let first = pages.iter().find(|p| p["page"] == 0);
    assert!(first.is_none(), "a page out of view, and unchanged, was sent");

    // A run a half-typed construct stops shows as halted once it has lasted, and no longer
    // once the construct is closed.
    let two = units_to(paged, "Page two");
    for (edit, halted) in [("\\textbf{", true), ("", false)] {
        main_doc.edit(two, 8 - edit.len() as u32, edit);
        let halted = |e: &Value| e["halted"] == halted;
        c.event(&mut from, a, "live", halted).await;
    }

    // Another session's Start takes the project's preview over; closing the first then
    // leaves the new one running.
    c.ask(a, "save", json!({})).await;
    let mut ended = c.count();
    let b = c.open().await;
    let taken = c.document(b, "main.tex").await;
    c.start(b).await;
    let owner = format!("\\typeout{{UL_REPLACEMENT_OWNER}}\n{paged}");
    retype(&taken, &owner);
    c.shows(b, "UL_REPLACEMENT_OWNER").await;
    let stopped = |e: &Value| e["phase"] == "stopped";
    c.event(&mut ended, a, "live", stopped).await;
    c.ask(a, "close", json!({})).await;
    retype(&taken, &owner.replace("UL_REPLACEMENT_OWNER", "UL_AFTER_CLOSE"));
    c.shows(b, "UL_AFTER_CLOSE").await;

    // TeXpresso never ended on its own, and no failure was reported.
    assert!(c.since(0, "live_restarted").is_empty());
    let lives = c.since(0, "live");
    let failed = lives.iter().find(|e| !e["failure"].is_null());
    assert!(failed.is_none(), "{failed:?}");
    let stopped = c.ask(b, "live_stop", json!({})).await;
    assert_eq!(stopped["phase"], "stopped");
    c.ask(b, "close", json!({})).await;
}
