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
        for (key, dir) in [
            ("XDG_CACHE_HOME", "cache"),
            ("TEXMFVAR", "texmf-var"),
            ("TEXMFCONFIG", "texmf-config"),
        ] {
            std::env::set_var(key, scratch.path().join(dir));
        }
    }
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(run(&scratch.path().join("projects")));
}

/// The longest any one thing may take.
const PATIENCE: Duration = Duration::from_secs(90);

/// A project's sessions, as a host has them, and every event they sent.
struct Client {
    sessions: Sessions,
    events: Arc<Mutex<Vec<Value>>>,
    id: String,
    /// The last session's number: a host numbers its own.
    numbered: AtomicU64,
}

impl Client {
    async fn open(&self) -> u64 {
        let session = self.numbered.fetch_add(1, Ordering::Relaxed) + 1;
        let args = json!({ "id": self.id, "session": session });
        let opened = self.call("session_open", args).await;
        opened["session"].as_u64().unwrap()
    }

    /// `session_<command>` in `session`.
    async fn ask(&self, session: u64, command: &str, mut args: Value) -> Value {
        args["session"] = json!(session);
        self.call(&format!("session_{command}"), args).await
    }

    async fn call(&self, command: &str, args: Value) -> Value {
        let answer = self.sessions.call(command, &args).await;
        answer.unwrap_or_else(|err| panic!("{command}: {} {}", err.status, err.message))
    }

    /// The document at `path` the editor of `session` edits.
    async fn document(&self, session: u64, path: &str) -> Document {
        self.ask(session, "open_document", json!({ "path": path }))
            .await;
        self.sessions.document(session, path).unwrap()
    }

    /// Starts the preview of `session`, its Live Preview Log shown, as a host does with the
    /// log open.
    async fn start(&self, session: u64) {
        self.ask(session, "live_log", json!({ "shown": true }))
            .await;
        let started = self.ask(session, "live_start", json!({})).await;
        assert_eq!(started["phase"], "running", "{started}");
    }

    /// Waits for a line of the Live Preview Log that starts with `text`, as TeX writes its
    /// lines, while the preview runs, across any restart of the session's own. Until TeX has
    /// said something the log has TeXpresso's stderr too, which may echo what it was sent.
    async fn shows(&self, session: u64, text: &str, check: &str) {
        let began = Instant::now();
        loop {
            let live = &self.ask(session, "state", json!({})).await["live"];
            let log = live["log"].as_str().unwrap();
            if live["phase"] == "running" && log.lines().any(|line| line.starts_with(text)) {
                break;
            }
            assert!(began.elapsed() < PATIENCE, "{check}: no {text} in {live}");
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        println!("{check}: {} ms", began.elapsed().as_millis());
    }

    /// The first event from `from` on that `wanted` takes, of `session` and `kind`; `from`
    /// moves past it.
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
                let found = later.find(|(_, event)| {
                    event["session"] == session && event["type"] == kind && wanted(event)
                });
                if let Some((at, event)) = found {
                    *from = at + 1;
                    return event.clone();
                }
            }
            assert!(began.elapsed() < PATIENCE, "no {kind} event wanted");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    /// Where the events stand once none has come for half a second.
    async fn settled(&self) -> usize {
        let mut seen = usize::MAX;
        loop {
            let count = self.events.lock().unwrap().len();
            if count == seen {
                return count;
            }
            seen = count;
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }

    /// The events of `kind` from `from` on.
    fn since(&self, from: usize, kind: &str) -> Vec<Value> {
        let events = self.events.lock().unwrap();
        let later = events[from..].iter().filter(|event| event["type"] == kind);
        later.cloned().collect()
    }
}

/// Types `text` over the document's own, as one edit of the range that differs, in
/// UTF-16 units as the editor counts. The texts here differ by whole characters.
fn retype(document: &Document, text: &str) {
    let old: Vec<u16> = document.with(|source| source.text().encode_utf16().collect());
    let new: Vec<u16> = text.encode_utf16().collect();
    let start = old.iter().zip(&new).take_while(|(a, b)| a == b).count();
    let (old, new) = (&old[start..], &new[start..]);
    let backwards = old.iter().rev().zip(new.iter().rev());
    let end = backwards.take_while(|(a, b)| a == b).count();
    let inserted = String::from_utf16(&new[..new.len() - end]).unwrap();
    document.edit(start as u32, (old.len() - end) as u32, &inserted);
}

fn is_pdf(path: &Path) {
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
    let project = service
        .call(
            "create_project",
            &json!({ "name": "TeXpresso check", "template": "blank" }),
        )
        .await
        .unwrap();
    let id = project["id"].as_str().unwrap().to_owned();
    let root = service.project_root(&id).unwrap();
    let sessions = Sessions::new(Arc::clone(&service));
    let events = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&events);
    sessions.set_listener(Some(Box::new(move |event| {
        sink.lock().unwrap().push(event.clone());
    })));
    let client = Client {
        sessions,
        events,
        id: id.clone(),
        numbered: AtomicU64::new(0),
    };
    let main = "\\documentclass{article}\n\\begin{document}\n\\typeout{UL_MAIN_INITIAL}\nHello café. $x^2+y^2=z^2$\n\\input{section.tex}\n\\end{document}\n";
    let section = "\\typeout{UL_SECTION_INITIAL}\nIncluded text.\n";
    for (path, text) in [("main.tex", main), ("section.tex", section)] {
        std::fs::write(root.join(path), text).unwrap();
    }
    let engine = json!({ "id": id, "patch": { "engine": "xelatex" } });
    service.call("set_settings", &engine).await.unwrap();

    // As the Mac app starts it: the pages in view first, the document shown in its pane.
    let a = client.open().await;
    let main_doc = client.document(a, "main.tex").await;
    client
        .ask(a, "live_view", json!({ "first": 1, "last": 1 }))
        .await;
    client.start(a).await;
    client
        .shows(a, "UL_SECTION_INITIAL", "The main and included files")
        .await;

    // Unsaved edits, to the main file and an included one opened while it runs, errors
    // and recovery.
    let unicode = main
        .replace("UL_MAIN_INITIAL", "UL_MAIN_UNSAVED")
        .replace("Hello café.", "Unsaved café — naïve.");
    retype(&main_doc, &unicode);
    client
        .shows(a, "UL_MAIN_UNSAVED", "An unsaved Unicode edit")
        .await;
    let section_doc = client.document(a, "section.tex").await;
    retype(
        &section_doc,
        &section.replace("UL_SECTION_INITIAL", "UL_SECTION_UNSAVED"),
    );
    client
        .shows(
            a,
            "UL_SECTION_UNSAVED",
            "An unsaved edit to an included file",
        )
        .await;
    let broken = unicode.replace("Unsaved café", "\\UnderleafInvalidCommand\nUnsaved café");
    let mut from = client.events.lock().unwrap().len();
    retype(&main_doc, &broken);
    client
        .shows(a, "! Undefined control sequence", "A LaTeX error")
        .await;
    // The log the host shows follows TeX's by itself, as the `live` event carries it.
    let error = |e: &Value| {
        e["log"]
            .as_str()
            .is_some_and(|log| log.contains("! Undefined"))
    };
    client.event(&mut from, a, "live", error).await;
    let recovered = unicode.replace("UL_MAIN_UNSAVED", "UL_MAIN_RECOVERED");
    retype(&main_doc, &recovered);
    client
        .shows(a, "UL_MAIN_RECOVERED", "Recovery without a restart")
        .await;

    // Each half-typed text reaches the engine, which must survive it.
    let end = recovered.find("\\end{document}").unwrap();
    let incomplete = [
        recovered.replace("$x^2+y^2=z^2$", "$x^2+y^2=z^2"),
        recovered.replace("$x^2+y^2=z^2$", "\\[x^2+y^2=z^2"),
        format!("{}\\", &recovered[..end]),
        recovered.replace("Unsaved café", "\\fra Unsaved café"),
        recovered.replace("Unsaved café", "\\textbf{Unsaved café"),
        recovered.replace("Unsaved café", "\\begin{itemize}\\item Unsaved café"),
        "\\documentclass{artic".to_owned(),
    ];
    for (index, text) in incomplete.iter().enumerate() {
        retype(&main_doc, text);
        tokio::time::sleep(Duration::from_millis(700)).await;
        let marker = format!("UL_TYPING_RECOVERED_{index}");
        retype(&main_doc, &recovered.replace("UL_MAIN_RECOVERED", &marker));
        client.shows(a, &marker, &format!("Typing {text:?}")).await;
    }

    // A build beside the preview.
    let mut from = client.events.lock().unwrap().len();
    client.ask(a, "compile", json!({})).await;
    let built = client.event(&mut from, a, "build_finished", |_| true).await;
    let result = &built["result"];
    assert_eq!(result["ok"], true, "{}", result["log"]);
    is_pdf(Path::new(result["pdf"].as_str().unwrap()));
    retype(
        &section_doc,
        &section.replace("UL_SECTION_INITIAL", "UL_AFTER_BUILD"),
    );
    client
        .shows(a, "UL_AFTER_BUILD", "The preview beside a build")
        .await;

    // A main file in a folder, its inputs from there: the session starts the preview
    // again for it.
    for (path, text) in [
        (
            "nested/main.tex",
            main.replace("UL_MAIN_INITIAL", "UL_NESTED_MAIN"),
        ),
        (
            "nested/section.tex",
            section.replace("UL_SECTION_INITIAL", "UL_NESTED_SECTION"),
        ),
    ] {
        std::fs::create_dir_all(root.join("nested")).unwrap();
        std::fs::write(root.join(path), text).unwrap();
    }
    // It stays `starting` meanwhile: a host told it stopped would show the build's PDF.
    let restarted = client.events.lock().unwrap().len();
    let nested = json!({ "patch": { "mainFile": "nested/main.tex" } });
    client.ask(a, "set_settings", nested).await;
    client
        .shows(a, "UL_NESTED_SECTION", "A nested main file's input")
        .await;
    let phases = client.since(restarted, "live");
    let stopped = phases.iter().find(|e| e["phase"] == "stopped");
    assert!(stopped.is_none(), "{stopped:?}");
    let nested_doc = client.document(a, "nested/section.tex").await;
    retype(
        &nested_doc,
        "\\typeout{UL_NESTED_UNSAVED}\nNested live edit.\n",
    );
    client
        .shows(a, "UL_NESTED_UNSAVED", "An edit to a nested input")
        .await;

    // The pages in view as PDFs of their own as they change, and the whole document when
    // typing pauses. Only a build with Underleaf's patch (tools/texpresso) sends them.
    let main_again = json!({ "patch": { "mainFile": "main.tex" } });
    client.ask(a, "set_settings", main_again).await;
    let marker = format!("UL_TYPING_RECOVERED_{}", incomplete.len() - 1);
    client.shows(a, &marker, "The main file again").await;
    let paged = "\\documentclass{article}\n\\begin{document}\nPage one café.\n\\newpage\nPage two.\n\\end{document}\n";
    let paging = client.events.lock().unwrap().len();
    retype(&main_doc, paged);
    let mut from = paging;
    let whole = client
        .event(&mut from, a, "live_document", |e| {
            e["pages"] == 2 && e["complete"] == true
        })
        .await;
    let path = Path::new(whole["path"].as_str().unwrap()).to_owned();
    is_pdf(&path);
    let synctex = std::fs::read(path.with_extension("synctex")).unwrap();
    assert!(!synctex.is_empty());

    // An offset in UTF-16 units, past the é that is two bytes to TeXpresso.
    let mut from = client.settled().await;
    let began = Instant::now();
    main_doc.edit(units_to(paged, "two"), 0, "number ");
    let page = client
        .event(&mut from, a, "live_page", |e| e["page"] == 1)
        .await;
    is_pdf(Path::new(page["path"].as_str().unwrap()));
    println!(
        "A key on the page in view: {} ms",
        began.elapsed().as_millis()
    );
    let after = client
        .event(&mut from, a, "live_document", |e| e["complete"] == true)
        .await;
    assert_eq!(after["changed"], json!([[1, 1]]));
    let pages = client.since(paging, "live_page");
    assert!(
        !pages.iter().any(|p| p["page"] == 0),
        "a page out of view, and unchanged, was sent"
    );

    // A run a half-typed construct stops shows as halted once it has lasted, and no longer
    // once the construct is closed.
    let two = units_to(paged, "Page two");
    main_doc.edit(two, 0, "\\textbf{");
    let halted = |halted: bool| move |e: &Value| e["halted"] == halted;
    client.event(&mut from, a, "live", halted(true)).await;
    main_doc.edit(two, 8, "");
    client.event(&mut from, a, "live", halted(false)).await;

    // Another session's Start takes the project's preview over; closing the first then
    // leaves the new one running.
    client.ask(a, "save", json!({})).await;
    let mut ended = client.events.lock().unwrap().len();
    let b = client.open().await;
    let taken = client.document(b, "main.tex").await;
    client.start(b).await;
    let owner = format!("\\typeout{{UL_REPLACEMENT_OWNER}}\n{paged}");
    retype(&taken, &owner);
    client
        .shows(b, "UL_REPLACEMENT_OWNER", "The new owner's text")
        .await;
    let stopped = |e: &Value| e["phase"] == "stopped";
    client.event(&mut ended, a, "live", stopped).await;
    client.ask(a, "close", json!({})).await;
    retype(
        &taken,
        &owner.replace("UL_REPLACEMENT_OWNER", "UL_OWNER_AFTER_CLOSE"),
    );
    client
        .shows(
            b,
            "UL_OWNER_AFTER_CLOSE",
            "The new owner's after the old closed",
        )
        .await;

    // TeXpresso never ended on its own, and no failure was reported.
    assert!(client.since(0, "live_restarted").is_empty());
    let failed = client.since(0, "live");
    let failed = failed.iter().find(|e| !e["failure"].is_null());
    assert!(failed.is_none(), "{failed:?}");
    let stopped = client.ask(b, "live_stop", json!({})).await;
    assert_eq!(stopped["phase"], "stopped");
    client.ask(b, "close", json!({})).await;
}
