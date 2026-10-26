use std::path::Path;
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
    unsafe {
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

const PATIENCE: Duration = Duration::from_secs(90);

struct Client {
    sessions: Arc<Sessions>,
    events: Arc<Mutex<Vec<Value>>>,
}

impl Client {
    async fn ask(&self, session: u64, command: &str, mut args: Value) -> Value {
        args["session"] = json!(session);
        self.call(&format!("session_{command}"), args).await
    }

    async fn call(&self, command: &str, args: Value) -> Value {
        let answer = self.sessions.call(command, args).await;
        answer.unwrap_or_else(|err| panic!("{command}: {:?} {}", err.kind, err.message))
    }

    async fn document(&self, session: u64, path: &str) -> Document {
        self.ask(session, "open_document", json!({ "path": path }))
            .await;
        self.sessions.document(session, path).unwrap()
    }

    async fn start(&self, session: u64) {
        self.ask(session, "live_log", json!({ "shown": true }))
            .await;
        let started = self.ask(session, "live_start", json!({})).await;
        assert_eq!(started["phase"], "running", "{started}");
    }

    async fn shows(&self, session: u64, text: &str, check: &str) {
        let began = Instant::now();
        loop {
            let live = {
                let events = self.events.lock().unwrap();
                let mut lives = events.iter().rev();
                let last = lives.find(|e| e["type"] == "live" && e["session"] == session);
                last.cloned().unwrap_or_default()
            };
            let log = live["log"].as_str().unwrap_or_default();
            if live["phase"] == "running" && log.lines().any(|line| line.starts_with(text)) {
                break;
            }
            assert!(began.elapsed() < PATIENCE, "{check}: no {text} in {live}");
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        println!("{check}: {} ms", began.elapsed().as_millis());
    }

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

    fn since(&self, from: usize, kind: &str) -> Vec<Value> {
        let events = self.events.lock().unwrap();
        let later = events[from..].iter().filter(|event| event["type"] == kind);
        later.cloned().collect()
    }
}

fn retype(document: &Document, text: &str) {
    let old: Vec<u16> = document.with(|source| source.text().encode_utf16().collect());
    let new: Vec<u16> = text.encode_utf16().collect();
    let start = old.iter().zip(&new).take_while(|(a, b)| a == b).count();
    let (old, new) = (&old[start..], &new[start..]);
    let backwards = old.iter().rev().zip(new.iter().rev());
    let end = backwards.take_while(|(a, b)| a == b).count();
    let inserted = String::from_utf16(&new[..new.len() - end]).unwrap();
    document.edit(
        start as u32,
        (old.len() - end) as u32,
        &inserted,
        None,
        false,
    );
}

fn is_pdf(path: &Path) {
    let bytes = std::fs::read(path).unwrap();
    assert!(bytes.starts_with(b"%PDF-"), "{}", path.display());
}

fn units_to(text: &str, what: &str) -> u32 {
    text[..text.find(what).unwrap()].encode_utf16().count() as u32
}

async fn run(library: &Path) {
    std::fs::create_dir_all(library).unwrap();
    let service = Arc::new(Service::new(library.to_path_buf()));
    let project = service
        .call(
            "create_project",
            json!({ "name": "TeXpresso check", "template": "blank", "engine": "xelatex" }),
        )
        .await
        .unwrap();
    let id = project["id"].as_str().unwrap().to_owned();
    let root = service.project(&id).unwrap().root;
    let events = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&events);
    let listen = Box::new(move |event: &Value| sink.lock().unwrap().push(event.clone()));
    let sessions = Arc::new(Sessions::new(Arc::clone(&service), listen));
    let client = Client { sessions, events };
    let main = "\\documentclass{article}\n\\begin{document}\n\\typeout{UL_MAIN_INITIAL}\nHello café. $x^2+y^2=z^2$\n\\input{section.tex}\n\\end{document}\n";
    let section = "\\typeout{UL_SECTION_INITIAL}\nIncluded text.\n";
    for (path, text) in [("main.tex", main), ("section.tex", section)] {
        std::fs::write(root.join(path), text).unwrap();
    }

    let a = 1;
    client
        .call("session_open", json!({ "id": id, "session": a }))
        .await;
    let main_doc = client.document(a, "main.tex").await;
    client
        .ask(a, "live_view", json!({ "first": 1, "last": 1 }))
        .await;
    client.start(a).await;
    client
        .shows(a, "UL_SECTION_INITIAL", "The main and included files")
        .await;

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
    let error = |e: &Value| {
        e["log"]
            .as_str()
            .is_some_and(|log| log.contains("! Undefined"))
    };
    client.event(&mut from, a, "live", error).await;
    let on = |line: u32| {
        move |e: &Value| {
            let issue = &e["lines"][0];
            e["path"] == "main.tex"
                && issue["line"] == line
                && issue["compact"] == "Undefined: \\UnderleafInvalidCommand"
        }
    };
    client.event(&mut from, a, "live_issues", on(4)).await;
    main_doc.edit(0, 0, "%\n", None, false);
    client.event(&mut from, a, "live_issues", on(5)).await;
    tokio::time::sleep(Duration::from_millis(20)).await;
    let recovered = unicode.replace("UL_MAIN_UNSAVED", "UL_MAIN_RECOVERED");
    retype(&main_doc, &recovered);
    let cleared = |e: &Value| e["path"] == "main.tex" && e["lines"] == json!([]);
    client.event(&mut from, a, "live_issues", cleared).await;
    client
        .shows(a, "UL_MAIN_RECOVERED", "Recovery without a restart")
        .await;

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

    let mut from = client.settled().await;
    let began = Instant::now();
    main_doc.edit(units_to(paged, "two"), 0, "number ", None, false);
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

    let two = units_to(paged, "Page two");
    main_doc.edit(two, 0, "\\textbf{", None, false);
    let halted = |halted: bool| move |e: &Value| e["halted"] == halted;
    client.event(&mut from, a, "live", halted(true)).await;
    main_doc.edit(two, 8, "", None, false);
    client.event(&mut from, a, "live", halted(false)).await;

    let failed = client.since(0, "live");
    let failed = failed.iter().find(|e| !e["failure"].is_null());
    assert!(failed.is_none(), "{failed:?}");
    let stopped = client.ask(a, "live_stop", json!({})).await;
    assert_eq!(stopped["phase"], "stopped");
    client.ask(a, "close", json!({})).await;
}
