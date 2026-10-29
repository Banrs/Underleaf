#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};
use tempfile::TempDir;
use texlocal_core::service::Service;
use texlocal_core::session::{
    FileBuffer, LiveEvent, Pane, Preview, Project, Sessions, Sink, Status,
};
use texlocal_core::{CoreError, ErrorKind, messages};

#[derive(Debug, Deserialize)]
pub struct Refused {
    pub kind: ErrorKind,
    pub message: Value,
}

pub struct Library {
    pub dir: TempDir,
    pub service: Arc<Service>,
}

impl Library {
    pub fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("data")).unwrap();
        let service = Arc::new(Service::new(dir.path().join("data")));
        Self { dir, service }
    }

    pub fn path(&self, rel: &str) -> PathBuf {
        self.dir.path().join(rel)
    }

    pub async fn call(&self, command: &str, args: Value) -> Value {
        answer(command, self.service.call(command, args).await)
    }

    pub async fn refuse(&self, command: &str, args: Value) -> ErrorKind {
        self.service.call(command, args).await.unwrap_err().kind
    }

    pub async fn create(&self, name: &str, template: &str) -> String {
        let made = self
            .call(
                "CreateProject",
                json!({ "name": name, "template": template }),
            )
            .await;
        made["id"].as_str().unwrap().to_owned()
    }

    pub fn projects(&self) -> Value {
        json!(self.service.projects().unwrap())
    }

    pub fn project_root(&self, id: &str) -> PathBuf {
        self.service.project(id).unwrap().root
    }
}

fn answer(command: &str, result: Result<Value, impl std::fmt::Debug>) -> Value {
    result.unwrap_or_else(|err| panic!("{command}: {err:?}"))
}

pub fn names(list: &Value, key: &str) -> Vec<String> {
    list.as_array()
        .unwrap()
        .iter()
        .map(|item| item[key].as_str().unwrap().to_owned())
        .collect()
}

pub fn write(root: &Path, files: &[(&str, &str)]) {
    for (rel, text) in files {
        let path = root.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
}

pub struct Rig {
    pub library: Library,
    pub sessions: Arc<Sessions>,
    pub id: String,
    events: Receiver<Value>,
    seen: Mutex<Vec<Value>>,
    asked: AtomicU64,
}

pub const SESSION: u64 = 1;

impl Rig {
    pub async fn open(files: &[(&str, &str)]) -> Self {
        Self::open_with(files, |_| {}).await
    }

    pub async fn open_with(files: &[(&str, &str)], prepare: impl FnOnce(&Library)) -> Self {
        Self::start(files, prepare, None).await
    }

    pub async fn previewing(
        files: &[(&str, &str)],
        prepare: impl FnOnce(&Library),
        preview: Arc<FakePreview>,
    ) -> Self {
        Self::start(files, prepare, Some(preview)).await
    }

    async fn start(
        files: &[(&str, &str)],
        prepare: impl FnOnce(&Library),
        preview: Option<Arc<FakePreview>>,
    ) -> Self {
        let library = Library::new();
        let id = library.create("P", "blank").await;
        let root = library.project_root(&id);
        std::fs::remove_file(root.join("main.tex")).unwrap();
        write(&root, files);
        prepare(&library);
        let (tx, events) = channel();
        let tx = Mutex::new(tx);
        let listener = Box::new(move |said: String| {
            let _ = tx
                .lock()
                .unwrap()
                .send(serde_json::from_str::<Value>(&said).unwrap());
        });
        let service = Arc::clone(&library.service);
        let sessions = Arc::new(match preview {
            Some(preview) => {
                let compiler = Arc::new(Arc::clone(&service));
                Sessions::with_compiler(service, compiler, preview, true, listener)
            }
            None => Sessions::new(service, listener),
        });
        let rig = Self {
            library,
            sessions,
            id,
            events,
            seen: Mutex::default(),
            asked: AtomicU64::default(),
        };
        rig.call("OpenProject", json!({ "id": rig.id, "autoCompile": false }));
        rig
    }

    pub fn root(&self) -> PathBuf {
        self.library.project_root(&self.id)
    }

    pub fn call(&self, command: &str, args: Value) -> Value {
        self.call_to(SESSION, command, args)
    }

    pub fn call_to(&self, session: u64, command: &str, args: Value) -> Value {
        answer(command, self.reply(self.send(session, command, args)))
    }

    pub fn refuse(&self, command: &str, args: Value) -> ErrorKind {
        self.reply(self.send(SESSION, command, args))
            .unwrap_err()
            .kind
    }

    pub fn ask_library(&self, command: &str, args: Value) -> Result<Value, Refused> {
        let id = self.asked.fetch_add(1, Ordering::Relaxed);
        self.sessions.send(id, command, args);
        self.reply(id)
    }

    pub fn listed(&self, matching: impl Fn(&Value) -> bool) -> Value {
        let listed =
            |e: &Value| e["library"]["type"] == "projects" && matching(&e["library"]["value"]);
        self.find(listed)["library"]["value"].take()
    }

    pub fn send(&self, session: u64, command: &str, args: Value) -> u64 {
        let id = self.asked.fetch_add(1, Ordering::Relaxed);
        self.sessions.send_to(id, session, command, args);
        id
    }

    pub fn reply(&self, id: u64) -> Result<Value, Refused> {
        let mut reply = self.find(|e| e["reply"] == id);
        match reply.get_mut("ok") {
            Some(ok) => Ok(ok.take()),
            None => Err(serde_json::from_value(reply["error"].take()).unwrap()),
        }
    }

    pub fn open_document(&self, path: &str) -> texlocal_core::session::Document {
        assert_eq!(self.call("Open", json!({ "path": path })), path);
        self.sessions.document(SESSION, path).unwrap()
    }

    pub fn event(&self, kind: &str, matching: impl Fn(&Value) -> bool) -> Value {
        let event = |e: &Value| e["event"]["type"] == kind && matching(&e["event"]["value"]);
        self.find(event)["event"]["value"].take()
    }

    pub fn section(&self, kind: &str, matching: impl Fn(&Value) -> bool) -> Value {
        let section = |s: &Value| s["type"] == kind && matching(&s["value"]);
        self.event("section", section)["value"].take()
    }

    pub fn event_in(&self, session: u64, kind: &str, matching: impl Fn(&Value) -> bool) -> Value {
        let event = |e: &Value| {
            e["session"] == session && e["event"]["type"] == kind && matching(&e["event"]["value"])
        };
        self.find(event)["event"]["value"].take()
    }

    pub fn section_in(&self, session: u64, kind: &str, matching: impl Fn(&Value) -> bool) -> Value {
        let section = |s: &Value| s["type"] == kind && matching(&s["value"]);
        self.event_in(session, "section", section)["value"].take()
    }

    pub fn find(&self, matching: impl Fn(&Value) -> bool) -> Value {
        if let Some(found) = self.seen.lock().unwrap().iter().find(|e| matching(e)) {
            return found.clone();
        }
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let event = self
                .events
                .recv_timeout(left)
                .unwrap_or_else(|_| panic!("no matching event came"));
            self.seen.lock().unwrap().push(event.clone());
            if matching(&event) {
                return event;
            }
        }
    }

    pub fn heard(&self, kind: &str) -> bool {
        self.said().contains(&kind.to_owned())
    }

    pub fn said(&self) -> Vec<String> {
        let seen = self.seen.lock().unwrap();
        let kind = |e: &Value| match &e["event"] {
            Value::Null if e["library"].is_object() => "library".to_owned(),
            Value::Null => "reply".to_owned(),
            event if event["type"] == "section" => event["value"]["type"].as_str().unwrap().into(),
            event => event["type"].as_str().unwrap().into(),
        };
        seen.iter().map(kind).collect()
    }

    pub fn forget(&self) {
        self.seen.lock().unwrap().clear();
        while self.events.try_recv().is_ok() {}
    }
}

#[derive(Default)]
pub struct FakePreview {
    sink: Mutex<Option<Sink>>,
    pub log: Mutex<String>,
}

impl FakePreview {
    pub fn send(&self, event: LiveEvent) {
        if let Some(sink) = &*self.sink.lock().unwrap() {
            sink(event);
        }
    }
}

impl Preview for FakePreview {
    fn available(&self, _: &str) -> bool {
        true
    }

    fn start(
        &self,
        _: u64,
        _: &Project,
        _: &[FileBuffer],
        _: &str,
        _: &Pane,
        sink: Sink,
    ) -> Result<Status, CoreError> {
        *self.sink.lock().unwrap() = Some(sink);
        Ok(Status {
            running: true,
            ..Status::default()
        })
    }

    fn update(&self, _: u64, _: &str, _: &str) -> Result<(), CoreError> {
        Ok(())
    }

    fn edit(&self, _: u64, _: &str, _: usize, _: usize, _: &str) -> Result<(), CoreError> {
        Ok(())
    }

    fn view(&self, _: u64, _: u32, _: u32) -> Result<(), CoreError> {
        Ok(())
    }

    fn caret(&self, _: u64, _: &str, _: usize) -> Result<(), CoreError> {
        Ok(())
    }

    fn rescan(&self, _: u64) -> Result<(), CoreError> {
        Ok(())
    }

    fn mark(&self, _: u64, mark: u64) -> Result<(), CoreError> {
        self.send(LiveEvent::Synced(mark));
        Ok(())
    }

    fn tex_log(&self, _: u64) -> Option<String> {
        Some(self.log.lock().unwrap().clone())
    }

    fn status(&self, _: u64) -> Result<Status, CoreError> {
        Ok(Status::default())
    }

    fn stop_request(&self, _: u64) -> Status {
        self.sink.lock().unwrap().take();
        Status::default()
    }

    fn live_text(&self, _: u64, _: &str) -> Option<String> {
        None
    }

    fn live_pdf(&self, _: u64) -> Result<PathBuf, CoreError> {
        Err(CoreError::not_found(messages::texpresso_unsynced()))
    }

    fn stop(&self, _: &Path) -> Result<(), CoreError> {
        Ok(())
    }
}
