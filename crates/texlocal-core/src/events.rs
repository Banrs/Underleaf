use std::borrow::Cow;
use std::collections::HashMap;
use std::mem::{Discriminant, discriminant};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;

use schemars::{JsonSchema, Schema, SchemaGenerator};
use serde::Serialize;
use serde_json::Value;

use crate::CoreError;
use crate::service::LibrarySection;
use crate::session::{DiskConflict, SessionSection};
use crate::texpresso::PageRange;

pub type Listener = Box<dyn Fn(String) + Send>;

#[derive(Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub(crate) enum Said {
    Reply(Replied),
    Event(SessionEvent),
    Library(LibrarySection),
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct Replied {
    pub id: u64,
    pub answer: Answered,
}

#[derive(Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum Answered {
    Ok(#[schemars(with = "Payload")] Value),
    Error(CoreError),
}

impl From<Result<Value, CoreError>> for Answered {
    fn from(answer: Result<Value, CoreError>) -> Self {
        match answer {
            Ok(value) => Self::Ok(value),
            Err(error) => Self::Error(error),
        }
    }
}

struct Payload;

impl JsonSchema for Payload {
    fn schema_name() -> Cow<'static, str> {
        "Payload".into()
    }

    fn json_schema(_: &mut SchemaGenerator) -> Schema {
        true.into()
    }
}

pub(crate) struct Sent<S>(HashMap<Discriminant<S>, String>);

impl<S> Default for Sent<S> {
    fn default() -> Self {
        Self(HashMap::new())
    }
}

impl<S: Serialize> Sent<S> {
    pub fn changed(&mut self, section: &S) -> bool {
        let said = serde_json::to_string(section).expect("a section serialises");
        let kind = discriminant(section);
        let before = self.0.insert(kind, said);
        before.as_ref() != self.0.get(&kind)
    }
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
    Renamed(Renamed),
    Conflict(Conflict),
    FilesChanged(Vec<String>),
    BuildFinished(BuildFinished),
    LiveAlert,
    LivePage(LivePage),
    LiveDocument(LiveDocument),
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct Renamed {
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
    pub(crate) queue: mpsc::Sender<Said>,
}

impl Hub {
    pub fn new(listen: Listener) -> Self {
        let (queue, said) = mpsc::channel::<Said>();
        std::thread::Builder::new()
            .name("texlocal-events".into())
            .spawn(move || {
                for said in said {
                    let said = serde_json::to_string(&said).expect("what the core says serialises");
                    let _ = catch_unwind(AssertUnwindSafe(|| listen(said)));
                }
            })
            .expect("the event thread starts");
        Self { queue }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::messages;

    #[test]
    fn the_core_says_each_kind_of_thing_as_the_fixtures_show() {
        let fixtures = include_str!("../../texlocal-wire/fixtures/wire.json");
        let fixtures: Value = serde_json::from_str(fixtures).unwrap();
        let gone = CoreError::not_found(messages::no_such_session());
        let said = [
            Said::Reply(Replied {
                id: 7,
                answer: Ok(json!("main.tex")).into(),
            }),
            Said::Reply(Replied {
                id: 8,
                answer: Err(gone).into(),
            }),
            Said::Event(SessionEvent {
                session: 1,
                event: Event::LiveAlert,
            }),
            Said::Library(LibrarySection::Projects(Vec::new())),
        ];
        assert_eq!(json!(said), fixtures["said"]);
    }
}
