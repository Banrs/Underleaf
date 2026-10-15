//! Live preview end to end with a real TeXpresso, through `Service` as the hosts
//! call it: `TEXLOCAL_TEXPRESSO` names the program, and TeX Live must be on the
//! PATH. Headless, and everything it writes is in a temporary folder.
//!
//! cargo test -p texlocal-core --test texpresso_live -- --ignored --nocapture

use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use texlocal_core::CoreError;
use texlocal_core::service::Service;

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

/// A project in the service, and the live preview session the client owns.
struct Client {
    service: Service,
    id: String,
    session: Option<String>,
    latest: Value,
}

impl Client {
    /// `command` with the project and, after the first start, the session.
    async fn call(&mut self, command: &str, mut args: Value) -> Result<Value, CoreError> {
        let fields = args.as_object_mut().unwrap();
        fields.entry("id").or_insert(json!(self.id));
        if command.starts_with("texpresso_") && command != "texpresso_start" {
            fields.entry("session").or_insert(json!(self.session));
        }
        let answer = self.service.call(command, &args).await;
        if command == "texpresso_start"
            && let Ok(started) = &answer
        {
            self.session = started["session"].as_str().map(str::to_owned);
        }
        answer
    }

    async fn ok(&mut self, command: &str, args: Value) -> Value {
        self.call(command, args)
            .await
            .unwrap_or_else(|err| panic!("{command}: {} {}", err.status, err.message))
    }

    async fn refused(&mut self, command: &str, args: Value, status: u16) -> CoreError {
        let err = self.call(command, args).await.unwrap_err();
        assert_eq!(err.status, status, "{command}: {}", err.message);
        err
    }

    async fn update(&mut self, path: &str, text: &str) {
        self.ok("texpresso_update", json!({ "path": path, "text": text }))
            .await;
    }

    /// Waits for `text` in TeXpresso's output (compiler output only: stderr may echo
    /// what it was sent), the session running all the while.
    async fn shows(&mut self, text: &str, check: &str) {
        let began = Instant::now();
        loop {
            self.latest = self.ok("texpresso_status", json!({})).await;
            assert_eq!(self.latest["running"], true, "{check}: {}", self.latest);
            if self.latest["output"].as_str().unwrap().contains(text) {
                break;
            }
            assert!(
                began.elapsed() < Duration::from_secs(90),
                "{check}: no {text} in {}",
                self.latest["output"]
            );
            tokio::time::sleep(Duration::from_millis(75)).await;
        }
        println!("{check}: {} ms", began.elapsed().as_millis());
    }

    /// The events from `seq` on until one `wanted` takes, and the pages they named.
    async fn event(
        &mut self,
        seq: &mut u64,
        pages: &mut Vec<Value>,
        wanted: impl Fn(&Value) -> bool,
    ) -> Value {
        let began = Instant::now();
        loop {
            let events = self
                .ok("texpresso_wait", json!({ "after": *seq, "timeout": 5000 }))
                .await;
            assert_eq!(events["running"], true, "{events}");
            *seq = events["seq"].as_u64().unwrap();
            pages.extend(events["pages"].as_array().unwrap().iter().cloned());
            if wanted(&events) {
                return events;
            }
            assert!(began.elapsed() < Duration::from_secs(90), "{events}");
        }
    }
}

fn is_pdf(path: &str) {
    assert!(std::fs::read(path).unwrap().starts_with(b"%PDF-"), "{path}");
}

/// UTF-16 units before `what` in `text`, as the editor counts.
fn units_to(text: &str, what: &str) -> usize {
    text[..text.find(what).unwrap()].encode_utf16().count()
}

async fn run(library: &Path) {
    std::fs::create_dir_all(library).unwrap();
    let service = Service::new(library.to_path_buf());
    let project = service
        .call(
            "create_project",
            &json!({ "name": "TeXpresso check", "template": "blank" }),
        )
        .await
        .unwrap();
    let mut client = Client {
        service,
        id: project["id"].as_str().unwrap().to_owned(),
        session: None,
        latest: Value::Null,
    };
    let main = "\\documentclass{article}\n\\begin{document}\n\\typeout{UL_MAIN_INITIAL}\nHello café. $x^2+y^2=z^2$\n\\input{section.tex}\n\\end{document}\n";
    let section = "\\typeout{UL_SECTION_INITIAL}\nIncluded text.\n";
    for (path, text) in [("main.tex", main), ("section.tex", section)] {
        client
            .ok("write_file", json!({ "path": path, "text": text }))
            .await;
    }
    client
        .ok("set_settings", json!({ "patch": { "engine": "xelatex" } }))
        .await;
    let status = client.ok("texpresso_status", json!({})).await;
    assert_eq!(status["available"], true, "{status}");
    let main_buffer = |text: &str| json!({ "files": [{ "path": "main.tex", "text": text }] });
    let started = client.ok("texpresso_start", main_buffer(main)).await;
    assert_eq!(started["running"], true, "{started}");
    client
        .shows("UL_SECTION_INITIAL", "The main and included files")
        .await;

    // Unsaved edits, to the main file and an included one, errors and recovery.
    let unicode = main
        .replace("UL_MAIN_INITIAL", "UL_MAIN_UNSAVED")
        .replace("Hello café.", "Unsaved café — naïve.");
    client.update("main.tex", &unicode).await;
    client
        .shows("UL_MAIN_UNSAVED", "An unsaved Unicode edit")
        .await;
    let include = section.replace("UL_SECTION_INITIAL", "UL_SECTION_UNSAVED");
    client.update("section.tex", &include).await;
    client
        .shows("UL_SECTION_UNSAVED", "An unsaved edit to an included file")
        .await;
    let broken = unicode.replace("Unsaved café", "\\UnderleafInvalidCommand\nUnsaved café");
    client.update("main.tex", &broken).await;
    client
        .shows("Undefined control sequence", "A LaTeX error")
        .await;
    let recovered = unicode.replace("UL_MAIN_UNSAVED", "UL_MAIN_RECOVERED");
    client.update("main.tex", &recovered).await;
    client
        .shows("UL_MAIN_RECOVERED", "Recovery without a restart")
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
        client.update("main.tex", text).await;
        tokio::time::sleep(Duration::from_millis(700)).await;
        let marker = format!("UL_TYPING_RECOVERED_{index}");
        client
            .update("main.tex", &recovered.replace("UL_MAIN_RECOVERED", &marker))
            .await;
        client.shows(&marker, &format!("Typing {text:?}")).await;
    }
    for (path, saved) in [("main.tex", main), ("section.tex", section)] {
        let read = client.ok("read_file", json!({ "path": path })).await;
        assert_eq!(read["text"], saved, "the saved {path}");
    }

    // A build beside the preview.
    let compiled = client.ok("compile", json!({})).await;
    assert_eq!(compiled["ok"], true, "{}", compiled["log"]);
    let pdf = library
        .join(&client.id)
        .join(compiled["pdf"].as_str().unwrap());
    is_pdf(pdf.to_str().unwrap());
    let status = client.ok("texpresso_status", json!({})).await;
    assert_eq!(status["running"], true, "a build stopped the preview");

    // A start from elsewhere takes the session over, and its old owner is refused.
    let superseded = client.session.clone();
    let owner = recovered.replace("UL_MAIN_RECOVERED", "UL_REPLACEMENT_OWNER");
    client.ok("texpresso_start", main_buffer(&owner)).await;
    assert_ne!(client.session, superseded);
    client
        .shows("UL_REPLACEMENT_OWNER", "The new owner's text")
        .await;
    for command in [
        "texpresso_status",
        "texpresso_start",
        "texpresso_update",
        "texpresso_rescan",
        "texpresso_stop",
    ] {
        let args = json!({ "session": superseded, "path": "main.tex", "text": main });
        let err = client.refused(command, args, 409).await;
        assert!(err.message.contains("Another window started TeXpresso"));
    }
    let status = client.ok("texpresso_status", json!({})).await;
    assert_eq!(status["running"], true, "the old owner stopped the new one");

    // A main file in a folder, its inputs from there.
    let stopped = client.ok("texpresso_stop", json!({})).await;
    assert_eq!(stopped["running"], false);
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
        client
            .ok("write_file", json!({ "path": path, "text": text }))
            .await;
    }
    let nested = json!({ "patch": { "mainFile": "nested/main.tex" } });
    client.ok("set_settings", nested).await;
    client.ok("texpresso_start", json!({})).await;
    client
        .shows("UL_NESTED_SECTION", "A nested main file's input")
        .await;
    let edit = "\\typeout{UL_NESTED_UNSAVED}\nNested live edit.\n";
    client.update("nested/section.tex", edit).await;
    client
        .shows("UL_NESTED_UNSAVED", "An edit to a nested input")
        .await;
    client.ok("texpresso_stop", json!({})).await;

    // As the Mac app shows it: no window, and the pages in view as PDFs of their own as
    // they change. Only a build with Underleaf's patch (tools/texpresso) sends them.
    let main_again = json!({ "patch": { "mainFile": "main.tex" } });
    client.ok("set_settings", main_again).await;
    let paged = "\\documentclass{article}\n\\begin{document}\nPage one café.\n\\newpage\nPage two.\n\\end{document}\n";
    let mut start = main_buffer(paged);
    start["pdf"] = json!(true);
    start["view"] = json!([1, 1]);
    client.ok("texpresso_start", start).await;
    let (mut seq, mut pages) = (0, Vec::new());
    let first = client
        .event(&mut seq, &mut pages, |e| {
            !e["live"].is_null() || !e["pdf"].is_null()
        })
        .await;
    if first["live"].is_null() {
        println!("This TeXpresso sends no pages: page updates not checked.");
    } else {
        let complete = |e: &Value| e["pdf"]["run"] == "complete";
        let whole = match complete(&first) {
            true => first["pdf"].clone(),
            false => client.event(&mut seq, &mut pages, complete).await["pdf"].clone(),
        };
        assert_eq!(whole["pages"], 2);
        let path = whole["path"].as_str().unwrap();
        is_pdf(path);
        let synctex = std::fs::read(Path::new(path).with_extension("synctex")).unwrap();
        assert!(!synctex.is_empty());

        // An offset in UTF-16 units, past the é that is two bytes to TeXpresso.
        let began = Instant::now();
        let at = units_to(paged, "two");
        let typed = json!({ "path": "main.tex", "start": at, "remove": 0, "text": "number " });
        let edit = client.ok("texpresso_edit", typed).await["edit"].clone();
        let shown = |e: &Value| {
            e["pages"]
                .as_array()
                .unwrap()
                .iter()
                .any(|p| p["page"] == 1 && p["edit"].as_u64() >= edit.as_u64())
        };
        let events = client.event(&mut seq, &mut pages, shown).await;
        let page = events["pages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["page"] == 1);
        is_pdf(page.unwrap()["path"].as_str().unwrap());
        println!(
            "A key on the page in view: {} ms",
            began.elapsed().as_millis()
        );
        let after = client
            .event(&mut seq, &mut pages, |e| {
                complete(e) && e["pdf"]["edit"].as_u64() >= edit.as_u64()
            })
            .await;
        assert_eq!(after["pdf"]["changed"], json!([[1, 1]]));
        assert!(
            !pages.iter().any(|p| p["page"] == 0),
            "a page out of view, and unchanged, was sent"
        );

        let unfit = json!({ "path": "main.tex", "start": 9999, "remove": 0, "text": "x" });
        client.refused("texpresso_edit", unfit, 412).await;
        let other = json!({ "path": "section.tex", "start": 0, "remove": 0, "text": "x" });
        client.refused("texpresso_edit", other, 412).await;

        // A run a half-typed construct stops is told apart from one that ends.
        let two = units_to(paged, "Page two");
        let open = json!({ "path": "main.tex", "start": two, "remove": 0, "text": "\\textbf{" });
        client.ok("texpresso_edit", open).await;
        let done = |e: &Value| !e["done"].is_null();
        let stopped = client.event(&mut seq, &mut pages, done).await;
        assert_eq!(stopped["done"]["run"], "stopped");
        let close = json!({ "path": "main.tex", "start": two, "remove": 8, "text": "" });
        client.ok("texpresso_edit", close).await;
        let ended = client.event(&mut seq, &mut pages, done).await;
        assert_eq!(ended["done"], json!({ "pages": 2, "run": "complete" }));
    }
    let stopped = client.ok("texpresso_stop", json!({})).await;
    assert_eq!(stopped["running"], false);
}
