use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;

use serde_json::{Value, json};

use crate::CoreError;

pub type Listener = Box<dyn Fn(&Value) + Send>;

pub(crate) enum Queued {
    Event(Value),
    Reply {
        id: u64,
        answer: Result<Value, CoreError>,
    },
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
                        Queued::Event(event) => event,
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
