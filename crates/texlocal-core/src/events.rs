use std::borrow::Cow;
use std::mem::{Discriminant, discriminant};
use std::panic::{AssertUnwindSafe, PanicHookInfo, catch_unwind};
use std::sync::{Mutex, Once, mpsc};

use schemars::{JsonSchema, Schema, SchemaGenerator};
use serde::Serialize;
use serde_json::Value;
use serde_json::value::{RawValue, to_raw_value};

use crate::service::LibrarySection;
use crate::session::{DiskConflict, SessionSection};
use crate::synctex::ForwardLoc;
use crate::texpresso::PageRange;
use crate::{CoreError, lock};

pub type Listener = Box<dyn Fn(String) + Send>;

#[derive(Serialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub(crate) enum Said {
    Reply(Replied),
    Event(SessionEvent),
    Library(#[schemars(with = "LibrarySection")] Box<RawValue>),
    Log(Log),
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

#[derive(Serialize, JsonSchema)]
pub(crate) struct Log {
    pub level: LogLevel,
    pub text: String,
}

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) enum LogLevel {
    Error,
    Fault,
}

impl Log {
    fn panicked(info: &PanicHookInfo) -> Self {
        let thread = std::thread::current();
        let text = format!("thread '{}' {info}", thread.name().unwrap_or("<unnamed>"));
        Self {
            level: LogLevel::Fault,
            text,
        }
    }
}

pub(crate) struct Sent<S>(Vec<(Discriminant<S>, Box<RawValue>)>);

impl<S> Default for Sent<S> {
    fn default() -> Self {
        Self(Vec::new())
    }
}

impl<S: Serialize> Sent<S> {
    pub fn changed(&mut self, section: &S) -> Option<Box<RawValue>> {
        let said = to_raw_value(section).expect("a section serialises");
        let kind = discriminant(section);
        match self.0.iter_mut().find(|(sent, _)| *sent == kind) {
            Some((_, before)) if before.get() == said.get() => return None,
            Some((_, before)) => *before = said.clone(),
            None => self.0.push((kind, said.clone())),
        }
        Some(said)
    }

    pub fn each(&self) -> impl Iterator<Item = Box<RawValue>> {
        self.0.iter().map(|(_, said)| said.clone())
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
    Section(#[schemars(with = "SessionSection")] Box<RawValue>),
    DocumentReload(String),
    Renamed(Renamed),
    Conflict(Conflict),
    FilesChanged(Vec<String>),
    BuildFinished(BuildFinished),
    LiveAlert,
    LivePage(LivePage),
    LiveDocument(LiveDocument),
    #[expect(
        dead_code,
        reason = "the wire contract lands before the follow that sends it"
    )]
    LiveFollow(ForwardLoc),
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
}

static PANICS: Mutex<Option<mpsc::Sender<Said>>> = Mutex::new(None);

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

    pub(crate) fn log_panics(&self) {
        static HOOK: Once = Once::new();
        *lock(&PANICS) = Some(self.queue.clone());
        HOOK.call_once(|| {
            let shown = std::panic::take_hook();
            std::panic::set_hook(Box::new(move |info| {
                shown(info);
                let log = Said::Log(Log::panicked(info));
                if let Some(queue) = &*lock(&PANICS) {
                    let _ = queue.send(log);
                }
            }));
        });
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::messages;
    use crate::session::{Lifecycle, Stopped};
    use crate::tex::TexStatus;

    fn raw(section: impl Serialize) -> Box<RawValue> {
        to_raw_value(&section).unwrap()
    }

    #[test]
    fn the_core_says_each_kind_of_thing_as_the_fixtures_show() {
        let fixtures = include_str!("../../texlocal-wire/fixtures/wire.json");
        let fixtures: Value = serde_json::from_str(fixtures).unwrap();
        let gone = CoreError::not_found(messages::no_such_session());
        let text = "thread 'texlocal-session-1' panicked at src/session/build.rs:9:5:\nboom";
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
            Said::Event(SessionEvent {
                session: 1,
                event: Event::Section(raw(SessionSection::Lifecycle(Lifecycle::Stopped(
                    Stopped {
                        unsaved: vec!["main.tex".into()],
                    },
                )))),
            }),
            Said::Library(raw(LibrarySection::Projects(Vec::new()))),
            Said::Library(raw(LibrarySection::Tex(TexStatus {
                available: true,
                latexmk_version: Some("4.86".into()),
                found: Some("/Library/TeX/texbin".into()),
                ..TexStatus::default()
            }))),
            Said::Log(Log {
                level: LogLevel::Fault,
                text: text.into(),
            }),
        ];
        assert_eq!(json!(said), fixtures["said"]);
    }
}
