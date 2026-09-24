//! Managed application state: the shared command service, plus the shell-only
//! state for the quit handshake and the native menu.

use std::sync::atomic::AtomicBool;
use std::sync::Mutex;

use texlocal_core::service::Service;

#[derive(Debug)]
pub struct FlushOutcome {
    pub ok: bool,
    pub error: Option<String>,
}

pub struct AppState {
    pub service: Service,
    /// Resolved with the renderer's actual save outcome. A signal with no
    /// outcome would make success, failure, and timeout indistinguishable.
    pub flush_ack: Mutex<Option<tokio::sync::oneshot::Sender<FlushOutcome>>>,
    pub flushing: AtomicBool,
    /// A Quit request upgrades any close already in flight to a process exit.
    pub exit_after_flush: AtomicBool,
    pub menu: Mutex<Option<crate::menu::MenuState>>,
}

impl AppState {
    pub fn new(service: Service) -> Self {
        Self {
            service,
            flush_ack: Mutex::new(None),
            flushing: AtomicBool::new(false),
            exit_after_flush: AtomicBool::new(false),
            menu: Mutex::new(None),
        }
    }
}
