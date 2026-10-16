//! What the core tells its host unasked: one JSON object per event,
//! `{"type": …, "session": …, …}`, handed to one listener in the order made,
//! on a thread of the hub's own, so a slow host never holds a session up.
//! A new session's events are held back until the answer to its open has been
//! handed over (`Hub::hold`, `Hub::release`). docs/core-api.md lists the events.

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;
use std::sync::{Arc, PoisonError, RwLock};

use serde_json::Value;

use crate::lock;

pub type Listener = Box<dyn Fn(&Value) + Send + Sync>;

/// What the hub's thread is sent, in the order made.
enum Item {
    Event(Value),
    /// The session's events wait from here...
    Hold(u64),
    /// ...until here, when they go out in the order they came.
    Release(u64),
}

pub struct Hub {
    queue: std::sync::Mutex<Option<mpsc::Sender<Item>>>,
    listener: Arc<RwLock<Option<Listener>>>,
}

impl Default for Hub {
    fn default() -> Self {
        let (queue, items) = mpsc::channel::<Item>();
        let listener: Arc<RwLock<Option<Listener>>> = Arc::default();
        let held = Arc::clone(&listener);
        // Ends once every sender has gone: the hub's and its sessions'.
        let spawned = std::thread::Builder::new()
            .name("texlocal-events".into())
            .spawn(move || {
                let deliver = |event: &Value| {
                    let listener = held.read().unwrap_or_else(PoisonError::into_inner);
                    if let Some(listen) = listener.as_ref() {
                        // A host's panic must not end delivery for the rest.
                        let _ = catch_unwind(AssertUnwindSafe(|| listen(event)));
                    }
                };
                let mut waiting: HashMap<u64, Vec<Value>> = HashMap::new();
                for item in items {
                    match item {
                        Item::Hold(session) => {
                            waiting.entry(session).or_default();
                        }
                        Item::Release(session) => {
                            waiting.remove(&session).iter().flatten().for_each(&deliver);
                        }
                        Item::Event(event) => {
                            let session = event.get("session").and_then(Value::as_u64);
                            match session.and_then(|session| waiting.get_mut(&session)) {
                                Some(events) => events.push(event),
                                None => deliver(&event),
                            }
                        }
                    }
                }
            });
        Hub {
            queue: std::sync::Mutex::new(spawned.ok().map(|_| queue)),
            listener,
        }
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

    pub fn emit(&self, event: Value) {
        self.send(Item::Event(event));
    }

    fn send(&self, item: Item) {
        if let Some(queue) = lock(&self.queue).as_ref() {
            let _ = queue.send(item);
        }
    }

    /// Keeps back every event of `session` made from now on, until `release`.
    /// A session's open holds its events, so none reaches the listener
    /// before the host has the answer that names the session.
    pub(crate) fn hold(&self, session: u64) {
        self.send(Item::Hold(session));
    }

    /// Lets the events held for `session` go out, in order, and the later
    /// ones follow as they are made. Does nothing for a session not held.
    pub(crate) fn release(&self, session: u64) {
        self.send(Item::Release(session));
    }

    /// A sender for one session's events, in the hub's order.
    pub(crate) fn emitter(&self) -> Emitter {
        Emitter(lock(&self.queue).clone())
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.set_listener(None);
        lock(&self.queue).take();
    }
}

#[derive(Clone)]
pub(crate) struct Emitter(Option<mpsc::Sender<Item>>);

impl Emitter {
    pub(crate) fn send(&self, event: Value) {
        if let Some(queue) = &self.0 {
            let _ = queue.send(Item::Event(event));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::time::Duration;

    /// A hub whose listener hands each event's `n` on to the receiver.
    fn listened() -> (Hub, mpsc::Receiver<u64>) {
        let hub = Hub::default();
        let (seen, numbers) = mpsc::channel();
        hub.set_listener(Some(Box::new(move |event| {
            let _ = seen.send(event["n"].as_u64().unwrap());
        })));
        (hub, numbers)
    }

    /// The next `count` events' numbers, waiting up to five seconds for each.
    fn next(numbers: &mpsc::Receiver<u64>, count: usize) -> Vec<u64> {
        let wait = Duration::from_secs(5);
        (0..count)
            .map(|_| numbers.recv_timeout(wait).unwrap())
            .collect()
    }

    /// Whether nothing more arrives for a while.
    fn quiet(numbers: &mpsc::Receiver<u64>) -> bool {
        numbers.recv_timeout(Duration::from_millis(50)).is_err()
    }

    #[test]
    fn events_reach_the_listener_in_order_and_none_after_it_is_removed() {
        let (hub, numbers) = listened();
        let emitter = hub.emitter();
        for n in 0..50 {
            if n % 2 == 0 {
                hub.emit(json!({ "n": n }));
            } else {
                emitter.send(json!({ "n": n }));
            }
        }
        assert_eq!(next(&numbers, 50), (0..50).collect::<Vec<_>>());
        hub.set_listener(None);
        hub.emit(json!({ "n": 99 }));
        assert!(quiet(&numbers));
    }

    #[test]
    fn a_held_sessions_events_wait_for_its_release_and_others_go_on() {
        let (hub, numbers) = listened();
        hub.hold(1);
        let (one, two) = (hub.emitter(), hub.emitter());
        one.send(json!({ "session": 1, "n": 0 }));
        two.send(json!({ "session": 2, "n": 1 }));
        one.send(json!({ "session": 1, "n": 2 }));
        // The other session's event is first, though the held one's were made before it.
        assert_eq!(next(&numbers, 1), [1]);
        assert!(quiet(&numbers), "held back");
        hub.release(1);
        one.send(json!({ "session": 1, "n": 3 }));
        // In the order made, and the later ones follow at once.
        assert_eq!(next(&numbers, 3), [0, 2, 3]);
        // Releasing a session never held does nothing.
        hub.release(7);
        hub.emit(json!({ "session": 7, "n": 4 }));
        assert_eq!(next(&numbers, 1), [4]);
    }
}
