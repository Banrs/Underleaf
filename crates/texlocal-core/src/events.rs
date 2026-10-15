//! What the core tells its host unasked: one JSON object per event,
//! `{"type": …, "session": …, …}`, handed to one listener in the order made,
//! on a thread of the hub's own, so a slow host never holds a session up.
//! docs/core-api.md lists the events.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;
use std::sync::{Arc, PoisonError, RwLock};

use serde_json::Value;

use crate::lock;

pub type Listener = Box<dyn Fn(&Value) + Send + Sync>;

pub struct Hub {
    queue: std::sync::Mutex<Option<mpsc::Sender<Value>>>,
    listener: Arc<RwLock<Option<Listener>>>,
}

impl Default for Hub {
    fn default() -> Self {
        let (queue, events) = mpsc::channel::<Value>();
        let listener: Arc<RwLock<Option<Listener>>> = Arc::default();
        let held = Arc::clone(&listener);
        // Ends once every sender has gone: the hub's and its sessions'.
        let spawned = std::thread::Builder::new()
            .name("texlocal-events".into())
            .spawn(move || {
                for event in events {
                    let listener = held.read().unwrap_or_else(PoisonError::into_inner);
                    if let Some(listen) = listener.as_ref() {
                        // A host's panic must not end delivery for the rest.
                        let _ = catch_unwind(AssertUnwindSafe(|| listen(&event)));
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
        if let Some(queue) = lock(&self.queue).as_ref() {
            let _ = queue.send(event);
        }
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
pub(crate) struct Emitter(Option<mpsc::Sender<Value>>);

impl Emitter {
    pub(crate) fn send(&self, event: Value) {
        if let Some(queue) = &self.0 {
            let _ = queue.send(event);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Mutex;
    use std::time::Duration;

    #[test]
    fn events_reach_the_listener_in_order_and_none_after_it_is_removed() {
        let hub = Hub::default();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        hub.set_listener(Some(Box::new(move |event| {
            sink.lock().unwrap().push(event["n"].as_u64().unwrap());
        })));
        let emitter = hub.emitter();
        for n in 0..50 {
            if n % 2 == 0 {
                hub.emit(json!({ "n": n }));
            } else {
                emitter.send(json!({ "n": n }));
            }
        }
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while seen.lock().unwrap().len() < 50 && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(*seen.lock().unwrap(), (0..50).collect::<Vec<_>>());
        hub.set_listener(None);
        hub.emit(json!({ "n": 99 }));
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(seen.lock().unwrap().len(), 50);
    }
}
