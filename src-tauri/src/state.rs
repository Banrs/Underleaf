//! Managed application state: where projects live, the compile manager, and
//! the two caches that keep repeated UI polling off the filesystem.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use texlocal_core::compile::{CompileManager, TexStatus};
use texlocal_core::projects::{FileStamp, Symbols};

/// How long a "no TeX found" answer is trusted before re-probing. The UI polls
/// every 10s while TeX is missing, and each probe would otherwise spawn
/// `latexmk -version`. Deliberately shorter than that interval: at exactly 10s
/// the entry is still fresh when the next tick arrives, so every other poll
/// would be answered from cache and an install would take 20s to notice.
const TEX_MISSING_TTL: Duration = Duration::from_secs(5);

#[derive(Default)]
struct StatusCache {
    /// Once TeX is found it cannot disappear from under a running app in any
    /// way worth re-probing for, so a positive answer is cached for the
    /// session; a negative one carries the instant it was taken.
    available: Option<TexStatus>,
    checked_at: Option<Instant>,
}

pub struct AppState {
    pub data_dir: PathBuf,
    pub compile: CompileManager,
    status: Mutex<StatusCache>,
    /// Per project: the stat-only fingerprint the cached symbols were built
    /// from. refreshSymbols() fires after every save, and re-reading every
    /// .tex/.bib in a large project each time is the wasteful part.
    symbols: Mutex<HashMap<PathBuf, (Vec<FileStamp>, Symbols)>>,
    /// Resolved when the renderer acknowledges the pre-quit flush.
    pub flush_ack: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    /// True while a flush is in flight, so a second close (or Quit during a
    /// close) doesn't start a rival handshake. Cleared once the flush settles —
    /// on macOS the app outlives its window, and the next close needs its own.
    pub flushing: AtomicBool,
    /// The native menu, and the item handles its updates are applied to.
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
            menu: Mutex::new(None),
        }
    }

    /// The cached TeX status, if still trustworthy.
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

    /// Drop a project's cached symbols — after a rename or delete the old key
    /// no longer names anything.
    pub fn forget_project(&self, root: &Path) {
        self.symbols.lock().unwrap().remove(root);
    }
}
