use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;

use serde_json::Value;

pub type Listener = Box<dyn Fn(&Value) + Send>;

pub(crate) enum Queued {
    Event(Value),
    Then(Box<dyn FnOnce() + Send>),
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
                    match queued {
                        Queued::Event(event) => {
                            let _ = catch_unwind(AssertUnwindSafe(|| listen(&event)));
                        }
                        Queued::Then(then) => then(),
                    }
                }
            })
            .expect("the event thread starts");
        Self { queue }
    }
}
