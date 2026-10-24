//! What the core tells its host unasked: one JSON object per event, handed to one listener in
//! order on the hub's own thread, so a slow host never holds a session up. docs/core-api.md lists
//! the events.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;
use std::sync::{Arc, PoisonError, RwLock};

use serde_json::Value;

pub type Listener = Box<dyn Fn(&Value) + Send + Sync>;

pub(crate) enum Queued {
    Event(Value),
    /// Done once the listener has had the events before it: an answer that follows them.
    Then(Box<dyn FnOnce() + Send>),
}

pub struct Hub {
    /// Each session sends on its own clone.
    pub(crate) queue: mpsc::Sender<Queued>,
    listener: Arc<RwLock<Option<Listener>>>,
}

impl Default for Hub {
    fn default() -> Self {
        let (queue, events) = mpsc::channel::<Queued>();
        let listener = Arc::<RwLock<Option<Listener>>>::default();
        let held = Arc::clone(&listener);
        // A hub that can't deliver would lose every event unseen, so a failed
        // spawn panics, and tl_open turns that into its NULL.
        std::thread::Builder::new()
            .name("texlocal-events".into())
            .spawn(move || {
                for queued in events {
                    let event = match queued {
                        Queued::Event(event) => event,
                        Queued::Then(then) => {
                            then();
                            continue;
                        }
                    };
                    let listener = held.read().unwrap_or_else(PoisonError::into_inner);
                    if let Some(listen) = listener.as_ref() {
                        // A host's panic must not end delivery for the rest.
                        let _ = catch_unwind(AssertUnwindSafe(|| listen(&event)));
                    }
                }
            })
            .expect("the event thread starts");
        Self { queue, listener }
    }
}

impl Hub {
    /// Replaces the listener. Returns once no call to the old one is running,
    /// so a host may free what it captured.
    pub fn set_listener(&self, listener: Option<Listener>) {
        *self
            .listener
            .write()
            .unwrap_or_else(PoisonError::into_inner) = listener;
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.set_listener(None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::time::Duration;

    #[test]
    fn events_reach_the_listener_in_order_and_none_after_it_is_removed() {
        let hub = Hub::default();
        let (seen, numbers) = mpsc::channel();
        hub.set_listener(Some(Box::new(move |event| {
            let _ = seen.send(event["n"].as_u64().unwrap());
        })));
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
        hub.set_listener(None);
        one.send(Queued::Event(json!({ "n": 99 }))).unwrap();
        assert!(numbers.recv_timeout(Duration::from_millis(50)).is_err());
    }
}
