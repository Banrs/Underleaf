//! Managed application state: where projects live, the compile manager, and
//! the two caches that keep repeated UI polling off the filesystem.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use texlocal_core::compile::{CompileManager, TexStatus};
use texlocal_core::projects::{FileStamp, Symbols};

const TEX_MISSING_TTL: Duration = Duration::from_secs(5);

#[derive(Default)]
struct StatusCache {
    available: Option<TexStatus>,
    checked_at: Option<Instant>,
}

#[derive(Debug)]
pub struct FlushOutcome {
    pub ok: bool,
    pub error: Option<String>,
}

pub struct AppState {
    pub data_dir: PathBuf,
    pub compile: CompileManager,
    status: Mutex<StatusCache>,
    symbols: Mutex<HashMap<PathBuf, (Vec<FileStamp>, Symbols)>>,
    /// Resolved with the renderer's actual save outcome. A signal with no
    /// outcome would make success, failure, and timeout indistinguishable.
    pub flush_ack: Mutex<Option<tokio::sync::oneshot::Sender<FlushOutcome>>>,
    pub flushing: AtomicBool,
    /// A Quit request upgrades any close already in flight to a process exit.
    pub exit_after_flush: AtomicBool,
    pub menu: Mutex<Option<crate::menu::MenuState>>,
}

impl AppState {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            compile: CompileManager::new(),
            status: Mutex::new(StatusCache::default()),
            symbols: Mutex::new(HashMap::new()),
            flush_ack: Mutex::new(None),
            flushing: AtomicBool::new(false),
            exit_after_flush: AtomicBool::new(false),
            menu: Mutex::new(None),
        }
    }

    pub fn cached_status(&self) -> Option<TexStatus> {
        let cache = self.status.lock().unwrap();
        let status = cache.available.as_ref()?;
        if status.available {
            return Some(status.clone());
        }
        let fresh = cache
            .checked_at
            .is_some_and(|at| at.elapsed() < TEX_MISSING_TTL);
        fresh.then(|| status.clone())
    }

    pub fn store_status(&self, status: TexStatus, now: Instant) {
        let mut cache = self.status.lock().unwrap();
        cache.available = Some(status);
        cache.checked_at = Some(now);
    }

    pub fn cached_symbols(&self, root: &Path, stamps: &[FileStamp]) -> Option<Symbols> {
        let cache = self.symbols.lock().unwrap();
        let (cached_stamps, symbols) = cache.get(root)?;
        (cached_stamps == stamps).then(|| symbols.clone())
    }

    pub fn store_symbols(&self, root: &Path, stamps: Vec<FileStamp>, symbols: Symbols) {
        self.symbols
            .lock()
            .unwrap()
            .insert(root.to_path_buf(), (stamps, symbols));
    }

    pub fn forget_project(&self, root: &Path) {
        self.symbols.lock().unwrap().remove(root);
    }
}
