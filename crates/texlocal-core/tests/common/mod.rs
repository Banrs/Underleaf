#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tempfile::TempDir;
use texlocal_core::service::Service;
use texlocal_core::session::Sessions;
use texlocal_core::{CoreError, ErrorKind};

pub struct Library {
    pub dir: TempDir,
    pub service: Arc<Service>,
}

impl Library {
    pub fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let service = Arc::new(Service::new(dir.path().join("data")));
        Self { dir, service }
    }

    pub fn path(&self, rel: &str) -> PathBuf {
        self.dir.path().join(rel)
    }

    pub async fn call(&self, command: &str, args: Value) -> Value {
        answer(command, self.service.call(command, args).await)
    }

    pub async fn refuse(&self, command: &str, args: Value) -> CoreError {
        self.service.call(command, args).await.unwrap_err()
    }

    pub async fn create(&self, name: &str, template: &str) -> String {
        let made = self
            .call(
                "create_project",
                json!({ "name": name, "template": template }),
            )
            .await;
        made["id"].as_str().unwrap().to_owned()
    }

    pub fn project_root(&self, id: &str) -> PathBuf {
        self.service.project(id).unwrap().root
    }
}

fn answer(command: &str, result: Result<Value, CoreError>) -> Value {
    result.unwrap_or_else(|err| panic!("{command}: {:?} {}", err.kind, err.message))
}

pub fn kind(result: Result<Value, CoreError>) -> ErrorKind {
    result.unwrap_err().kind
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
        let library = Library::new();
        let id = library.create("P", "blank").await;
        let root = library.project_root(&id);
        std::fs::remove_file(root.join("main.tex")).unwrap();
        write(&root, files);
        prepare(&library);
        let (tx, events) = channel();
        let tx = Mutex::new(tx);
        let listener = Box::new(move |event: &Value| {
            let _ = tx.lock().unwrap().send(event.clone());
        });
        let sessions = Arc::new(Sessions::new(Arc::clone(&library.service), listener));
        let rig = Self {
            library,
            sessions,
            id,
            events,
            seen: Mutex::default(),
            asked: AtomicU64::default(),
        };
        rig.call("session_open", json!({ "id": rig.id, "session": SESSION }))
            .await;
        rig
    }

    pub fn root(&self) -> PathBuf {
        self.library.project_root(&self.id)
    }

    pub async fn call(&self, command: &str, args: Value) -> Value {
        answer(command, self.try_call(command, args).await)
    }

    pub async fn try_call(&self, command: &str, args: Value) -> Result<Value, CoreError> {
        self.reply(self.send(command, args))
    }

    pub fn send(&self, command: &str, mut args: Value) -> u64 {
        if command.starts_with("session_") {
            let args = args.as_object_mut().unwrap();
            args.entry("session").or_insert(json!(SESSION));
        }
        let id = self.asked.fetch_add(1, Ordering::Relaxed);
        self.sessions.send(id, command, args);
        id
    }

    pub fn reply(&self, id: u64) -> Result<Value, CoreError> {
        let mut reply = self.find(|e| e["reply"] == id);
        match reply.get_mut("ok") {
            Some(ok) => Ok(ok.take()),
            None => Err(CoreError {
                kind: serde_json::from_value(reply["kind"].take()).unwrap(),
                message: reply["error"].as_str().unwrap().to_owned(),
            }),
        }
    }

    pub async fn open_document(&self, path: &str) -> texlocal_core::session::Document {
        self.call("session_open_document", json!({ "path": path }))
            .await;
        self.sessions.document(SESSION, path).unwrap()
    }

    pub fn event(&self, kind: &str, matching: impl Fn(&Value) -> bool) -> Value {
        self.find(|e| e["type"] == kind && matching(e))
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
        self.seen.lock().unwrap().iter().any(|e| e["type"] == kind)
    }

    pub fn forget(&self) {
        self.seen.lock().unwrap().clear();
        while self.events.try_recv().is_ok() {}
    }

    pub fn latest(&self, kind: &str, matching: impl Fn(&Value) -> bool) -> Value {
        self.event(kind, &matching);
        while let Ok(event) = self.events.recv_timeout(Duration::from_millis(300)) {
            self.seen.lock().unwrap().push(event);
        }
        self.seen
            .lock()
            .unwrap()
            .iter()
            .rev()
            .find(|e| e["type"] == kind && matching(e))
            .cloned()
            .unwrap()
    }
}
