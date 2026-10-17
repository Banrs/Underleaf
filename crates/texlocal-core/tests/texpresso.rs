//! The live preview's TeXpresso sessions (`texpresso::Manager`) through a
//! stand-in TeXpresso, a shell script that keeps each command it is sent.
//! Unix-only, as the stand-ins are; CI runs it on macOS.
#![cfg(unix)]

mod support;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use texlocal_core::CoreError;
use texlocal_core::texpresso::{Caret, Document, Events, FileBuffer, Manager, Pane, Status};

/// Upstream's build: it starts an "engine", prints output and a document,
/// and keeps what it is sent until EXIT_CLEAN or EXIT_STUB. WRITE_LOG has it
/// write TeX's log and a diagnostic on stderr; BACKTRACK takes the log back.
const UPSTREAM: &str = r#"/bin/sleep 300 &
echo $! > "$STUB/engine.pid"
echo $$ >> "$STUB/pids"
echo "${TEXPRESSO_PDF_OUTPUT-none}" > "$STUB/pdf"
printf '["append","out",0,"ready"]\n'
printf '["pdf","%s",1]\n' "$TEXPRESSO_PDF_OUTPUT"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$STUB/commands"
  case "$line" in
    *EXIT_CLEAN*) exit 0;;
    *EXIT_STUB*) exit 7;;
    *WRITE_LOG*) printf '["append","log",0,"Undefined control sequence"]\n'
      echo 'Undefined control sequence' >&2;;
    *BACKTRACK*) printf '["truncate","log",0]\n';;
  esac
done
"#;

/// A build with Underleaf's patch: it says so first, writes "the document"
/// and its SyncTeX, and answers each change with page 1 in a file of its
/// own. A rescan has it write a new document, then a page from outside its
/// folder, then the end of the run.
const PATCHED: &str = r#"dir=${TEXPRESSO_PDF_OUTPUT%/*}
n=0
: > "${TEXPRESSO_PDF_OUTPUT%.pdf}.synctex"
printf '["live",1]\n["pdf","%s",3,"partial",[[0,2]],0]\n' "$TEXPRESSO_PDF_OUTPUT"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$STUB/commands"
  case "$line" in
    '["change",'*) n=$((n + 1))
      printf '["page",1,"%s/page-1-%s.pdf",0]\n' "$dir" "$n";;
    '["rescan"]') printf '["pdf","%s",4,"complete",[[1,1],[3,3]],0]\n["page",0,"/etc/passwd",0]\n["done",4,"complete"]\n' "$TEXPRESSO_PDF_OUTPUT";;
  esac
done
"#;

/// The project session numbered 1, a host's first.
const OWNER: u64 = 1;
const SOON: Duration = Duration::from_secs(3);

/// A project whose main.tex holds "disk text", and a manager whose
/// TeXpresso is the stand-in running `script`.
struct Stub {
    tmp: tempfile::TempDir,
    root: PathBuf,
    path_env: String,
    manager: Arc<Manager>,
}

impl Stub {
    fn new(script: &str) -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let (root, bin) = (tmp.path().join("project"), tmp.path().join("bin"));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("main.tex"), "disk text").unwrap();
        let script = format!("STUB='{}'\n{script}", tmp.path().display());
        support::program(&bin, "texpresso", &script);
        let path_env = bin.to_string_lossy().into_owned();
        let manager = Arc::default();
        Self { tmp, root, path_env, manager }
    }

    fn start(
        &self,
        owner: u64,
        main: Option<&str>,
        replacing: bool,
        pane: Option<&Pane>,
    ) -> Result<Status, CoreError> {
        let file = |text: &str| FileBuffer { path: "main.tex".into(), text: text.into() };
        let files: Vec<_> = main.map(file).into_iter().collect();
        let manager = &self.manager;
        manager.start(owner, &self.root, &files, replacing, &self.path_env, pane)
    }

    /// The user's Start, with the main file open as `main` says.
    fn begin(&self, owner: u64, main: Option<&str>) -> Status {
        self.start(owner, main, false, Some(&Pane::default())).unwrap()
    }

    /// The owner's own restart, which takes back only a preview still its own.
    fn restart(&self, owner: u64) -> Result<Status, CoreError> {
        self.start(owner, None, true, Some(&Pane::default()))
    }

    /// What the stand-in wrote to `file`.
    fn read(&self, file: &str) -> String {
        fs::read_to_string(self.tmp.path().join(file)).unwrap_or_default()
    }

    fn commands(&self) -> Vec<Value> {
        let parse = |line| serde_json::from_str(line).unwrap();
        self.read("commands").lines().map(parse).collect()
    }

    /// The commands once the stand-in has had those `ready` waits for.
    async fn sent(&self, ready: impl Fn(&[Value]) -> bool) -> Vec<Value> {
        until(|| ready(&self.commands())).await;
        self.commands()
    }

    /// The process ids of the stand-ins started.
    fn pids(&self) -> Vec<i32> {
        self.read("pids").lines().map(|p| p.parse().unwrap()).collect()
    }

    fn main(&self) -> PathBuf {
        dunce::canonicalize(self.root.join("main.tex")).unwrap()
    }

    async fn wait(&self, owner: u64, after: u64) -> Events {
        let wait = self.manager.wait(owner, after);
        let answer = tokio::time::timeout(SOON, wait).await;
        answer.expect("an answer").unwrap()
    }

    /// The first document the session hands its client.
    async fn first_document(&self) -> Document {
        let mut events = self.wait(OWNER, 0).await;
        while events.pdf.is_none() {
            events = self.wait(OWNER, events.seq).await;
        }
        events.pdf.unwrap()
    }

    /// Until the owner's preview has stopped.
    async fn stopped(&self, owner: u64) {
        until(|| !self.manager.status(owner).unwrap().running).await;
    }
}

async fn until(mut check: impl FnMut() -> bool) {
    tokio::time::timeout(SOON, async {
        while !check() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the stand-in made progress");
}

/// Until the process `pid` has gone, reaped.
async fn gone(pid: i32) {
    until(|| unsafe { libc::kill(pid, 0) } == -1).await;
}

fn has(verb: &'static str) -> impl Fn(&[Value]) -> bool {
    move |sent| sent.iter().any(|c| c[0] == verb)
}

fn verbs(sent: &[Value]) -> Vec<Value> {
    sent.iter().map(|c| c[0].clone()).collect()
}

/// The status code of a refusal.
fn refused<T>(result: Result<T, CoreError>) -> u16 {
    result.err().expect("refused").status
}

/// `text` with a change TeXpresso was sent made to it.
fn apply(text: &mut String, change: &Value) {
    let start = change[2].as_u64().unwrap() as usize;
    let end = start + change[3].as_u64().unwrap() as usize;
    text.replace_range(start..end, change[4].as_str().unwrap());
}

#[tokio::test]
async fn a_preview_has_the_buffers_their_changes_and_a_folder_of_its_own() {
    use std::os::unix::fs::PermissionsExt;
    let stub = Stub::new(UPSTREAM);
    let (original, updated) = ("prefix é😀 suffix", "prefix ê😃 suffix");
    // A main file named texpresso-live.tex builds this; live preview leaves it.
    let normal = stub.root.join("build").join("texpresso-live.pdf");
    fs::create_dir_all(normal.parent().unwrap()).unwrap();
    fs::write(&normal, "normal build").unwrap();
    let first = stub.begin(OWNER, Some(original));
    assert!(first.running);
    // The session's own, outside the project, for its owner alone: never a build's.
    let pdf = PathBuf::from(stub.first_document().await.path);
    let root = dunce::canonicalize(&stub.root).unwrap();
    assert!(pdf.ends_with("live.pdf") && !pdf.starts_with(root));
    let folder = pdf.parent().unwrap().to_owned();
    let mode = fs::metadata(&folder).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o700);
    assert_eq!(fs::read(&normal).unwrap(), b"normal build");
    let sent = stub.sent(has("open")).await;
    assert_eq!(sent[0], json!(["open", stub.main(), original]));

    stub.manager.update(OWNER, "main.tex", updated).unwrap();
    let second = stub.manager.status(OWNER).unwrap();
    assert!(second.running && second.revision > first.revision);
    let sent = stub.sent(has("change")).await;
    let mut text = original.to_owned();
    apply(&mut text, &sent[1]);
    assert_eq!(text, updated);
    let disk = fs::read_to_string(stub.root.join("main.tex")).unwrap();
    assert_eq!(disk, "disk text");
    let too_large = "x".repeat((8 << 20) + 1);
    let outside = [("../escape.tex", "bad"), ("build/out.tex", "bad")];
    for (path, text) in outside.into_iter().chain([("main.tex", &*too_large)]) {
        assert!(stub.manager.update(OWNER, path, text).is_err());
    }
    stub.manager.rescan(OWNER).unwrap();
    stub.sent(has("rescan")).await;

    // The owner's Stop ends its ownership and removes the folder.
    assert!(!stub.manager.stop_request(OWNER).unwrap().running);
    assert!(!folder.exists());
    assert_eq!(refused(stub.restart(OWNER)), 409);
    let restarted = stub.begin(OWNER, None);
    assert!(restarted.running && restarted.revision > second.revision);
    stub.manager.update(OWNER, "main.tex", "EXIT_CLEAN").unwrap();
    stub.stopped(OWNER).await;
    assert!(stub.manager.status(OWNER).unwrap().error.is_none());
    stub.begin(OWNER, None);
    stub.manager.kill_all();
    assert!(!stub.manager.status(OWNER).unwrap().running);
}

#[tokio::test]
async fn whole_texts_follow_one_another_and_a_new_main_file_stops_the_session() {
    let stub = Stub::new(UPSTREAM);
    stub.begin(OWNER, Some("abc"));
    let changes = || -> Vec<Value> {
        let sent = stub.commands().into_iter();
        sent.filter(|c| c[0] == "change").collect()
    };
    // TeXpresso's copy, rebuilt from the changes it is sent; the same text again
    // sends none.
    let mut text = String::from("abc");
    for edit in ["abXc", "aXc", "aXc", "aXcd"] {
        let before = changes().len();
        stub.manager.update(OWNER, "main.tex", edit).unwrap();
        if text != edit {
            until(|| changes().len() > before).await;
            apply(&mut text, changes().last().unwrap());
        }
        assert_eq!(text, edit);
    }
    assert_eq!(changes().len(), 3);

    fs::write(stub.root.join("other.tex"), "").unwrap();
    let other = json!({ "mainFile": "other.tex" });
    texlocal_core::settings::write_settings(&stub.root, &other).unwrap();
    stub.manager.update(OWNER, "main.tex", "abc").unwrap();
    let status = stub.manager.status(OWNER).unwrap();
    assert!(!status.running);
    assert!(status.error.unwrap().contains("main file changed"));
}

/// The log follows TeX's backtracking, and has the program's own output only
/// once it has failed; the output stays, and the engine goes with it.
#[tokio::test]
async fn an_unexpected_exit_keeps_the_output_and_stops_the_engines_group() {
    let stub = Stub::new(UPSTREAM);
    stub.begin(OWNER, None);
    let status = || stub.manager.status(OWNER).unwrap();
    until(|| !stub.read("engine.pid").is_empty() && status().output == "ready").await;
    let engine: i32 = stub.read("engine.pid").trim().parse().unwrap();
    // Backtracking drops TeX's log, and stderr's history is not put in its place.
    let diagnostic = "Undefined control sequence";
    stub.manager.update(OWNER, "main.tex", "WRITE_LOG").unwrap();
    until(|| status().log.contains(diagnostic)).await;
    stub.manager.update(OWNER, "main.tex", "BACKTRACK").unwrap();
    until(|| !status().log.contains(diagnostic)).await;

    stub.manager.update(OWNER, "main.tex", "EXIT_STUB").unwrap();
    stub.stopped(OWNER).await;
    let ended = status();
    assert_eq!(ended.output, "ready");
    assert!(ended.error.unwrap().contains("exited") && ended.log.contains(diagnostic));
    assert!(!stub.wait(OWNER, 0).await.running);
    gone(engine).await;
}

#[tokio::test]
async fn another_sessions_start_takes_over_and_a_stop_ends_ownership() {
    let stub = Stub::new(UPSTREAM);
    let manager = &stub.manager;
    let (old, current) = (OWNER, OWNER + 1);
    stub.begin(old, None);
    until(|| stub.pids().len() == 1).await;
    stub.begin(current, Some("owner B"));
    // The old owner's late calls change nothing.
    assert_eq!(refused(manager.update(old, "main.tex", "stale A")), 409);
    assert_eq!(refused(manager.edit(old, "main.tex", 0, 0, "x")), 409);
    assert_eq!(refused(manager.status(old)), 409);
    assert_eq!(refused(manager.rescan(old)), 409);
    assert_eq!(refused(manager.stop_request(old)), 409);
    assert_eq!(refused(manager.wait(old, 0).await), 409);
    assert_eq!(refused(stub.restart(old)), 409);
    assert!(manager.status(current).unwrap().running);
    let opened = json!(["open", stub.main(), "owner B"]);
    stub.sent(|sent| sent.contains(&opened)).await;
    until(|| stub.pids().len() == 2).await;
    // A rename's stop keeps the owner, whose restart takes the preview back.
    manager.stop(&stub.root).unwrap();
    assert!(!manager.status(current).unwrap().running);
    assert!(stub.restart(current).unwrap().running);
    // The previews stopped are over, their programs reaped.
    for pid in &stub.pids()[..2] {
        gone(*pid).await;
    }
    // The owner's Stop ends its ownership too.
    assert!(!manager.stop_request(current).unwrap().running);
    assert_eq!(refused(stub.restart(current)), 409);
}

#[tokio::test]
async fn a_keystroke_goes_as_bytes_at_once_and_one_that_does_not_fit_is_refused() {
    let stub = Stub::new(PATCHED);
    let manager = &stub.manager;
    let caret = Caret { path: "main.tex".into(), offset: 4 };
    let pane = Pane { view: Some((2, 3)), caret: Some(caret) };
    stub.start(OWNER, Some("aé😀b"), false, Some(&pane)).unwrap();
    let path = stub.main();
    // Four units in: after a, é and the pair, seven bytes in.
    manager.edit(OWNER, "main.tex", 4, 0, "X").unwrap();
    manager.edit(OWNER, "main.tex", 1, 3, "").unwrap();
    manager.view(OWNER, 5, 4).unwrap();
    manager.caret(OWNER, "main.tex", 2).unwrap();
    let sent = stub.sent(|sent| sent.len() >= 7).await;
    assert_eq!(
        sent[1..],
        [
            json!(["view", 2, 3]),
            json!(["caret", path, 7]),
            json!(["change", path, 7, 0, "X"]),
            json!(["change", path, 1, 6, ""]),
            json!(["view", 5, 5]),
            json!(["caret", path, 2]),
        ]
    );

    // The copy is "aXb" now: nothing below is in it, and nothing is sent or changed.
    let unfit = [("main.tex", 4, 0), ("main.tex", 2, 2), ("other.tex", 0, 0)];
    for (file, start, remove) in unfit {
        assert_eq!(refused(manager.edit(OWNER, file, start, remove, "no")), 412);
    }
    assert_eq!(refused(manager.caret(OWNER, "main.tex", 9)), 412);
    assert_eq!(refused(manager.edit(OWNER, "main.tex", 0, 0, "\0")), 400);
    assert_eq!(refused(manager.edit(OWNER + 1, "main.tex", 0, 0, "x")), 409);
    // The whole text puts the copy right, sent as the change from what TeXpresso has.
    manager.update(OWNER, "main.tex", "aXb😀").unwrap();
    manager.edit(OWNER, "main.tex", 5, 0, "!").unwrap();
    let sent = stub.sent(|sent| sent.len() >= 9).await;
    let changes = [json!(["change", path, 3, 0, "😀"]), json!(["change", path, 7, 0, "!"])];
    assert_eq!(sent[7..], changes);
    // No finishing passes of upstream's kind, which start the document over.
    assert!(!has("rerun")(&sent));
    // A session that has ended takes an edit as nothing, and refuses none.
    manager.stop(&stub.root).unwrap();
    manager.edit(OWNER, "main.tex", 0, 0, "x").unwrap();
}

#[tokio::test]
async fn waiting_hands_over_the_latest_of_each_page_and_ends_with_the_session() {
    let stub = Stub::new(PATCHED);
    stub.begin(OWNER, Some("abc"));
    let wait = |after: u64| {
        let manager = Arc::clone(&stub.manager);
        async move { manager.wait(OWNER, after).await.unwrap() }
    };
    // The build says what it speaks, then the first document, which has its
    // SyncTeX beside it.
    let document = stub.first_document().await;
    let first = stub.wait(OWNER, 0).await;
    assert_eq!((document.version, document.pages), (1, 3));
    assert_eq!(document.run.as_deref(), Some("partial"));
    assert_eq!(document.changed, Some(vec![[0, 2]]));
    assert!(first.pages.is_empty() && first.done.is_none() && first.running);
    let live = stub.manager.live_pdf(OWNER).unwrap();
    assert_eq!(live, Path::new(&document.path));
    // It said it sends pages, so it is told the pages in view.
    stub.manager.view(OWNER, 0, 0).unwrap();
    stub.sent(|sent| sent.contains(&json!(["view", 0, 0]))).await;

    // Nothing new: the wait goes on, and other calls go on meanwhile.
    let began = Instant::now();
    let waiting = tokio::spawn(wait(first.seq));
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!waiting.is_finished());
    stub.manager.edit(OWNER, "main.tex", 3, 0, "d").unwrap();
    stub.manager.edit(OWNER, "main.tex", 4, 0, "e").unwrap();
    let mut events = waiting.await.unwrap();
    assert!(began.elapsed() < SOON && events.seq > first.seq);
    while !events.pages.iter().any(|p| p.path.ends_with("-2.pdf")) {
        events = stub.wait(OWNER, events.seq).await;
    }
    // Two edits wrote page 1 twice: a client that was away has only the later.
    let all = stub.wait(OWNER, 0).await;
    let folder = Path::new(&document.path).parent().unwrap();
    assert_eq!(all.pages.len(), 1);
    let page = &all.pages[0];
    assert_eq!(page.page, 1);
    assert_eq!(Path::new(&page.path), folder.join("page-1-2.pdf"));
    assert!(page.serial > document.serial && all.pdf.unwrap().serial == document.serial);
    // And one that has seen it is told nothing twice: its wait goes on.
    let quiet = tokio::time::timeout(Duration::from_millis(60), wait(all.seq)).await;
    assert!(quiet.is_err());

    // A new document takes the place of the pages before it; a page file from
    // outside the session's folder, which follows it, is nobody's page.
    stub.manager.rescan(OWNER).unwrap();
    let mut events = stub.wait(OWNER, all.seq).await;
    while events.done.is_none() {
        events = stub.wait(OWNER, all.seq).await;
    }
    let document = events.pdf.unwrap();
    assert_eq!((document.version, document.pages), (2, 4));
    assert_eq!(document.run.as_deref(), Some("complete"));
    assert_eq!(document.changed, Some(vec![[1, 1], [3, 3]]));
    assert!(events.pages.is_empty());
    assert_eq!(events.done.unwrap(), "complete");

    // Stopping answers the wait at once.
    let waiting = tokio::spawn(wait(events.seq));
    tokio::time::sleep(Duration::from_millis(30)).await;
    let began = Instant::now();
    stub.manager.stop(&stub.root).unwrap();
    let ended = waiting.await.unwrap();
    assert!(!ended.running && began.elapsed() < Duration::from_secs(1));
    assert!(!stub.wait(OWNER, ended.seq).await.running);
    assert_eq!(refused(stub.manager.wait(OWNER + 1, 0).await), 409);
}

/// Only a build that has said it sends pages, or nothing yet, is told the view
/// and the caret: an older one only writes the document, and without a pane
/// TeXpresso shows the document in its own window, for which the session makes
/// no folder and offers none.
#[tokio::test]
async fn texpresso_is_told_no_view_or_caret_by_an_older_build_or_without_a_pane() {
    let stub = Stub::new(UPSTREAM);
    stub.begin(OWNER, Some("abc"));
    // No word of pages before the document: the build is an older one.
    let document = stub.first_document().await;
    assert_eq!((document.version, document.pages), (1, 1));
    assert!(document.run.is_none() && document.changed.is_none());
    stub.manager.edit(OWNER, "main.tex", 3, 0, "d").unwrap();
    stub.manager.view(OWNER, 0, 1).unwrap();
    stub.manager.caret(OWNER, "main.tex", 1).unwrap();
    stub.manager.rescan(OWNER).unwrap();
    let sent = stub.sent(has("rescan")).await;
    assert_eq!(verbs(&sent), ["open", "change", "rescan"]);

    let stub = Stub::new(UPSTREAM);
    stub.start(OWNER, Some("abc"), false, None).unwrap();
    stub.manager.view(OWNER, 0, 1).unwrap();
    stub.manager.caret(OWNER, "main.tex", 1).unwrap();
    stub.manager.update(OWNER, "main.tex", "EXIT_CLEAN").unwrap();
    stub.stopped(OWNER).await;
    assert_eq!(stub.read("pdf"), "none\n");
    // Its stand-in printed a document all the same, with no path to write it to.
    let events = stub.wait(OWNER, 0).await;
    assert!(events.pdf.is_none() && events.pages.is_empty());
    assert_eq!(refused(stub.manager.live_pdf(OWNER)), 404);
    assert_eq!(verbs(&stub.commands()), ["open", "change"]);
}
