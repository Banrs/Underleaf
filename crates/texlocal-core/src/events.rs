use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;

use schemars::JsonSchema;
use serde::Serialize;
use serde_json::{Value, json};
use texlocal_latex::analyze::Analysis;
use texlocal_latex::logparse::LogItem;
use texlocal_latex::syntax::TextRange;

use crate::CoreError;
use crate::compile::CompileResult;
use crate::projects::TreeNode;
use crate::session::{CloseReason, DiskConflict, LiveState};
use crate::texpresso::PageRange;

pub type Listener = Box<dyn Fn(&Value) + Send>;

pub(crate) enum Queued {
    Event(SessionEvent),
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
    Document(DocumentState),
    DocumentClosed(DocumentClosed),
    DocumentReload(DocumentReload),
    DocumentRenamed(DocumentRenamed),
    Conflict(Conflict),
    FilesChanged(Vec<String>),
    Tree(Vec<TreeNode>),
    Outline(Analysis),
    Build(BuildState),
    BuildFinished(BuildFinished),
    BuildCleaned,
    Checks(Vec<LogItem>),
    Issues(FileIssues),
    Live(LiveUpdate),
    LivePage(LivePage),
    LiveDocument(LiveDocument),
    LiveIssues(FileIssues),
}

#[derive(Clone, PartialEq, Serialize, JsonSchema)]
pub(crate) struct DocumentState {
    pub path: String,
    pub error: Option<String>,
    pub held: bool,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct DocumentClosed {
    pub path: String,
    pub reason: CloseReason,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct DocumentReload {
    pub path: String,
    pub text: String,
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

#[derive(Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
pub(crate) struct BuildState {
    pub compiling: bool,
    pub auto: bool,
    pub outdated: bool,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct BuildFinished {
    pub auto: bool,
    pub announce: bool,
    pub outdated: bool,
    pub result: CompileResult,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct FileIssues {
    pub path: String,
    pub lines: Vec<IssueLine>,
}

#[derive(Clone, PartialEq, Eq, Serialize, JsonSchema)]
pub(crate) struct IssueLine {
    pub line: u32,
    pub error: bool,
    pub message: String,
    pub short: String,
    pub compact: Option<String>,
    pub tokens: Vec<TextRange>,
    pub others: Vec<String>,
    pub index: Option<usize>,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct LiveUpdate {
    pub state: LiveState,
    pub alert: bool,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct LivePage {
    pub page: u32,
    pub path: String,
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
