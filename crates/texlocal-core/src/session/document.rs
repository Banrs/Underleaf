//! An open file's text, the session's: the editor edits it once per change; syntax
//! answers, saves and the live preview read it.

use std::sync::{Arc, Mutex, PoisonError, RwLock};

use tokio::sync::mpsc;

use super::Msg;
use crate::lock;
use crate::projects::Symbols;
use crate::syntax::SourceDocument;

struct Text {
    source: SourceDocument,
    version: u64,
}

struct Cell {
    id: u64,
    text: Mutex<Text>,
    tx: mpsc::UnboundedSender<Msg>,
    symbols: Arc<RwLock<Arc<Symbols>>>,
}

#[derive(Clone)]
pub struct Document(Arc<Cell>);

impl Document {
    pub(crate) fn new(
        id: u64,
        path: &str,
        text: &str,
        tx: mpsc::UnboundedSender<Msg>,
        symbols: Arc<RwLock<Arc<Symbols>>>,
    ) -> Self {
        Self(Arc::new(Cell {
            id,
            text: Mutex::new(Text {
                source: SourceDocument::named(text, path),
                version: 0,
            }),
            tx,
            symbols,
        }))
    }

    pub fn edit(&self, start: u32, length: u32, text: &str) {
        let mut held = lock(&self.0.text);
        held.source.edit(start, length, text);
        held.version += 1;
        // Sent under the lock, so the session has edits in the order made.
        let _ = self.0.tx.send(Msg::Edited {
            doc: self.0.id,
            version: held.version,
            start,
            length,
            text: text.to_owned(),
        });
    }

    pub fn reload(&self, text: &str) {
        let mut held = lock(&self.0.text);
        held.source = SourceDocument::named(text, &held.source.path);
        held.version += 1;
        let _ = self.0.tx.send(Msg::Reloaded {
            doc: self.0.id,
            version: held.version,
        });
    }

    /// The editor is about to show the document again, and what an earlier visit left isn't
    /// the new one's.
    pub fn reset_typing(&self) {
        lock(&self.0.text).source.reset_typing();
    }

    pub fn with<T>(&self, body: impl FnOnce(&mut SourceDocument) -> T) -> T {
        let symbols = self.symbols();
        let mut held = lock(&self.0.text);
        held.source.set_symbols(symbols);
        body(&mut held.source)
    }

    pub fn symbols(&self) -> Arc<Symbols> {
        let symbols = &self.0.symbols;
        Arc::clone(&symbols.read().unwrap_or_else(PoisonError::into_inner))
    }

    pub(crate) fn id(&self) -> u64 {
        self.0.id
    }

    pub(crate) fn moved(&self, path: &str) {
        path.clone_into(&mut lock(&self.0.text).source.path);
    }

    pub(crate) fn snapshot(&self) -> (String, u64) {
        let held = lock(&self.0.text);
        (held.source.text(), held.version)
    }

    pub fn version(&self) -> u64 {
        lock(&self.0.text).version
    }
}
