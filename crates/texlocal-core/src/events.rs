use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;

use schemars::JsonSchema;
use serde::Serialize;
use serde_json::{Value, json};

use crate::CoreError;
use crate::service::LibrarySection;
use crate::session::{DiskConflict, SessionSection};
use crate::texpresso::PageRange;

pub type Listener = Box<dyn Fn(&Value) + Send>;

pub(crate) enum Queued {
    Event(SessionEvent),
    Library(LibrarySection),
    Reply {
        id: u64,
        answer: Result<Value, CoreError>,
    },
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct SessionEvent {
    pub session: u64,
    pub event: Event,
}

#[derive(Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub(crate) enum Event {
    Section(SessionSection),
    DocumentReload(String),
    DocumentRenamed(DocumentRenamed),
    Conflict(Conflict),
    FilesChanged(Vec<String>),
    BuildFinished(BuildFinished),
    LiveAlert,
    LivePage(LivePage),
    LiveDocument(LiveDocument),
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct DocumentRenamed {
    pub from: String,
    pub to: String,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct Conflict {
    pub path: String,
    pub kind: DiskConflict,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct BuildFinished {
    pub auto: bool,
    pub announce: bool,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct LivePage {
    pub page: u32,
    #[schemars(extend("contentEncoding" = "base64"))]
    pub pdf: String,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct LiveDocument {
    pub path: String,
    pub changed: Vec<PageRange>,
    pub complete: bool,
}

pub struct Hub {
    pub(crate) queue: mpsc::Sender<Queued>,
}

impl Hub {
    pub fn new(listen: Listener) -> Self {
        let (queue, events) = mpsc::channel::<Queued>();
        std::thread::Builder::new()
            .name("texlocal-events".into())
            .spawn(move || {
                for queued in events {
                    let said = match queued {
                        Queued::Event(event) => json!(event),
                        Queued::Library(section) => json!({ "library": section }),
                        Queued::Reply { id, answer } => match answer {
                            Ok(ok) => json!({ "reply": id, "ok": ok }),
                            Err(err) => json!({ "reply": id, "error": err }),
                        },
                    };
                    let _ = catch_unwind(AssertUnwindSafe(|| listen(&said)));
                }
            })
            .expect("the event thread starts");
        Self { queue }
    }
}
