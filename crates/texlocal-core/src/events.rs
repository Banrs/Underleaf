//! What the core tells its host unasked: one JSON object per event,
//! `{"type": …, "session": …, …}`, handed to one listener in the order made,
//! on a thread of the hub's own, so a slow host never holds a session up.
//! A host numbers its sessions and listens for one before opening it, so
//! nothing is held back. docs/core-api.md lists the events.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc;
use std::sync::{Arc, PoisonError, RwLock};

use serde_json::Value;

pub type Listener = Box<dyn Fn(&Value) + Send + Sync>;

pub(crate) struct Hub {
    queue: Option<mpsc::Sender<Value>>,
    listener: Arc<RwLock<Option<Listener>>>,
}

impl Default for Hub {
    fn default() -> Self {
        let (queue, events) = mpsc::channel::<Value>();
        let listener: Arc<RwLock<Option<Listener>>> = Arc::default();
        let held = Arc::clone(&listener);
        // Ends once every sender has gone: the hub's and its sessions'.
        let spawned = std::thread::Builder::new().name("texlocal-events".into()).spawn(move || {
            for event in events {
                let listener = held.read().unwrap_or_else(PoisonError::into_inner);
                if let Some(listen) = listener.as_ref() {
                    // A host's panic must not end delivery for the rest.
                    let _ = catch_unwind(AssertUnwindSafe(|| listen(&event)));
                }
            }
        });
        Self { queue: spawned.ok().map(|_| queue), listener }
    }
}

impl Hub {
    /// Replaces the listener. Returns once no call to the old one is running,
    /// so a host may free what it captured: the thread holds the read lock
    /// through each call.
    pub(crate) fn set_listener(&self, listener: Option<Listener>) {
        *self.listener.write().unwrap_or_else(PoisonError::into_inner) = listener;
    }

    /// A sender for one session's events, in the hub's order.
    pub(crate) fn emitter(&self) -> Emitter {
        Emitter(self.queue.clone())
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.set_listener(None);
        self.queue = None;
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
    use std::time::Duration;

    #[test]
    fn events_reach_the_listener_in_order_and_none_after_it_is_removed() {
        let hub = Hub::default();
        let (seen, numbers) = mpsc::channel();
        hub.set_listener(Some(Box::new(move |event| {
            let _ = seen.send(event["n"].as_u64().unwrap());
        })));
        let (one, two) = (hub.emitter(), hub.emitter());
        for n in 0..50 {
            let emitter = if n % 2 == 0 { &one } else { &two };
            emitter.send(json!({ "n": n }));
        }
        let wait = Duration::from_secs(5);
        let received: Vec<u64> = (0..50).map(|_| numbers.recv_timeout(wait).unwrap()).collect();
        assert_eq!(received, (0..50).collect::<Vec<_>>());
        hub.set_listener(None);
        one.send(json!({ "n": 99 }));
        assert!(numbers.recv_timeout(Duration::from_millis(50)).is_err());
    }

    #[test]
    fn replacing_the_listener_waits_for_a_running_call_and_a_panic_ends_nothing() {
        let hub = Hub::default();
        let (started, running) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let released = std::sync::Mutex::new(released);
        let (order, log) = mpsc::channel();
        let call_order = order.clone();
        hub.set_listener(Some(Box::new(move |event| {
            if event["n"] == 0 {
                started.send(()).unwrap();
                released.lock().unwrap().recv().unwrap();
                let _ = call_order.send("call ended");
                panic!("a host's fault");
            }
        })));
        hub.emitter().send(json!({ "n": 0 }));
        running.recv_timeout(Duration::from_secs(5)).unwrap();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                hub.set_listener(None);
                let _ = order.send("replaced");
            });
            std::thread::sleep(Duration::from_millis(50));
            release.send(()).unwrap();
        });
        assert_eq!(log.try_iter().collect::<Vec<_>>(), ["call ended", "replaced"]);
    }
}
