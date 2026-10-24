//! What the core tells its host unasked: one JSON object per event, handed to one listener in
//! order on the hub's own thread, so a slow host never holds a session up. docs/core-api.md lists
//! the events.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;

use serde_json::Value;

pub type Listener = Box<dyn Fn(&Value) + Send>;

pub(crate) enum Queued {
    Event(Value),
    /// Done once the listener has had the events before it: an answer that follows them.
    Then(Box<dyn FnOnce() + Send>),
}

pub struct Hub {
    /// Each session sends on its own clone.
    pub(crate) queue: mpsc::Sender<Queued>,
}

impl Hub {
    pub fn new(listen: Listener) -> Self {
        let (queue, events) = mpsc::channel::<Queued>();
        // A hub that can't deliver would lose every event unseen, so a failed
        // spawn panics, and tl_open turns that into its NULL.
        std::thread::Builder::new()
            .name("texlocal-events".into())
            .spawn(move || {
                for queued in events {
                    match queued {
                        // A host's panic must not end delivery for the rest.
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::time::Duration;

    #[test]
    fn events_reach_the_listener_in_order() {
        let (seen, numbers) = mpsc::channel();
        let hub = Hub::new(Box::new(move |event| {
            let _ = seen.send(event["n"].as_u64().unwrap());
        }));
        let (one, two) = (hub.queue.clone(), hub.queue.clone());
        for n in 0..50 {
            let queue = if n % 2 == 0 { &one } else { &two };
            queue.send(Queued::Event(json!({ "n": n }))).unwrap();
        }
        let wait = Duration::from_secs(5);
        let received: Vec<u64> = (0..50)
            .map(|_| numbers.recv_timeout(wait).unwrap())
            .collect();
        assert_eq!(received, (0..50).collect::<Vec<_>>());
    }
}
