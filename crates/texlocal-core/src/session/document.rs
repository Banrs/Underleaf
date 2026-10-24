//! An open file's text, the session's: the editor edits it once per change; syntax
//! answers, saves and the live preview read it.

use std::sync::{Arc, Mutex, PoisonError, RwLock};

use tokio::sync::mpsc;

use super::Msg;
use crate::analyze::Facts;
use crate::lock;
use crate::projects::{Symbols, file_kind};
use crate::syntax::{SourceDocument, TextEdit, TextRange};

struct Text {
    source: SourceDocument,
    version: u64,
    /// Typed in since the session asked for a reload, which would lose it.
    edited: bool,
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
        let source = SourceDocument::named(text, path);
        let text = Mutex::new(Text {
            source,
            version: 0,
            edited: false,
        });
        Self(Arc::new(Cell {
            id,
            text,
            tx,
            symbols,
        }))
    }

    /// `SourceDocument::apply_edit`, told to the session.
    pub fn edit(
        &self,
        start: u32,
        length: u32,
        text: &str,
        changing: Option<TextRange>,
        mirroring: bool,
    ) -> Vec<TextEdit> {
        let mut held = lock(&self.0.text);
        let mirrors = (held.source).apply_edit(start, length, text, changing, mirroring);
        held.edited = true;
        let edit = TextEdit {
            start,
            length,
            text: text.to_owned(),
        };
        self.changed(&mut held, Some(edit));
        mirrors
    }

    /// The session asks for a reload of the text it saw at `version`.
    pub(crate) fn expect_reload(&self, version: u64) {
        let mut held = lock(&self.0.text);
        held.edited = held.version != version;
    }

    /// False, changing nothing, when keys were typed since the session asked for it: they would
    /// be lost, so the session asks about the change instead.
    pub fn reload(&self, text: &str) -> bool {
        let mut held = lock(&self.0.text);
        if held.edited {
            return false;
        }
        held.source = SourceDocument::named(text, &held.source.path);
        self.changed(&mut held, None);
        true
    }

    /// Sent under the lock, so the session has changes in the order made.
    fn changed(&self, held: &mut Text, edit: Option<TextEdit>) {
        held.version += 1;
        let (doc, version) = (self.0.id, held.version);
        let _ = self.0.tx.send(Msg::Changed { doc, version, edit });
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
        let symbols = self.0.symbols.read();
        Arc::clone(&symbols.unwrap_or_else(PoisonError::into_inner))
    }

    pub(crate) fn id(&self) -> u64 {
        self.0.id
    }

    pub(crate) fn moved(&self, path: &str) {
        path.clone_into(&mut lock(&self.0.text).source.path);
    }

    /// Read from a copy of the text, so the editor's keys don't wait on the parse.
    pub(crate) fn facts(&self) -> Facts {
        let (text, path) = {
            let held = lock(&self.0.text);
            (held.source.text(), held.source.path.clone())
        };
        Facts::read(&text, file_kind(&path))
    }

    pub(crate) fn snapshot(&self) -> (String, u64) {
        let held = lock(&self.0.text);
        (held.source.text(), held.version)
    }

    pub fn version(&self) -> u64 {
        lock(&self.0.text).version
    }
}
