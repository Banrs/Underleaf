//! An open file's text, the session's: the editor edits it once per change,
//! the syntax answers read it, and saves and the live preview take it.

use std::sync::{Arc, Mutex, PoisonError, RwLock};

use tokio::sync::mpsc;

use super::Msg;
use crate::lock;
use crate::projects::Symbols;
use crate::syntax::SourceDocument;

struct Text {
    source: SourceDocument,
    /// Rises with each edit and reload: the session saves and previews by it.
    version: u64,
    /// The scan last given to `source`, whose completions offer it.
    symbols: Option<Arc<Symbols>>,
}

struct Cell {
    id: u64,
    text: Mutex<Text>,
    tx: mpsc::UnboundedSender<Msg>,
    symbols: Arc<RwLock<Arc<Symbols>>>,
}

/// A handle on a session's document, cheap to clone; any thread may use it.
#[derive(Clone)]
pub struct Document(Arc<Cell>);

impl Document {
    pub(crate) fn new(
        id: u64,
        text: &str,
        tx: mpsc::UnboundedSender<Msg>,
        symbols: Arc<RwLock<Arc<Symbols>>>,
    ) -> Self {
        Self(Arc::new(Cell {
            id,
            text: Mutex::new(Text {
                source: SourceDocument::new(text),
                version: 0,
                symbols: None,
            }),
            tx,
            symbols,
        }))
    }

    /// The editor replaced `length` UTF-16 units at `start` with `text`.
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

    /// The editor now shows `text`, which a `document_reload` event gave it.
    pub fn reload(&self, text: &str) {
        let mut held = lock(&self.0.text);
        held.source = SourceDocument::new(text);
        held.symbols = None;
        held.version += 1;
        let _ = self.0.tx.send(Msg::Reloaded {
            doc: self.0.id,
            version: held.version,
        });
    }

    /// Forgets the closers and snippet typing kept: the editor is about to
    /// show the document again, and what an earlier visit left isn't the new one's.
    pub fn reset_typing(&self) {
        lock(&self.0.text).source.reset_typing();
    }

    /// Runs `body` on the text; nothing else reads or edits it meanwhile.
    pub fn with<T>(&self, body: impl FnOnce(&mut SourceDocument) -> T) -> T {
        let symbols = self.symbols();
        let mut held = lock(&self.0.text);
        if !held
            .symbols
            .as_ref()
            .is_some_and(|s| Arc::ptr_eq(s, &symbols))
        {
            let (labels, citations) = (symbols.labels.clone(), symbols.citations.clone());
            held.source.set_symbols(labels, citations);
            held.symbols = Some(symbols);
        }
        body(&mut held.source)
    }

    /// The project's labels and citations, which completions offer.
    pub fn symbols(&self) -> Arc<Symbols> {
        Arc::clone(
            &self
                .0
                .symbols
                .read()
                .unwrap_or_else(PoisonError::into_inner),
        )
    }

    pub(crate) fn id(&self) -> u64 {
        self.0.id
    }

    pub(crate) fn snapshot(&self) -> (String, u64) {
        let held = lock(&self.0.text);
        (held.source.text(), held.version)
    }

    pub(crate) fn version(&self) -> u64 {
        lock(&self.0.text).version
    }
}
