use std::sync::{Arc, Mutex, PoisonError, RwLock};

use texlocal_latex::facts::Facts;
use texlocal_latex::file_kind;
use texlocal_latex::project::Scan;
use texlocal_latex::syntax::{SourceDocument, Symbols, TextEdit, TextRange};
use texlocal_latex::utf16;
use tokio::sync::mpsc;

use super::Msg;
use crate::lock;

/// The main thread is the text's one writer: the session reads it and asks the main thread for reloads.
struct Text {
    source: SourceDocument,
    version: u64,
    closed: bool,
}

struct Cell {
    id: u64,
    text: Mutex<Text>,
    tx: mpsc::UnboundedSender<Msg>,
    scan: Arc<RwLock<Arc<Scan>>>,
}

#[derive(Clone)]
pub struct Document(Arc<Cell>);

impl Document {
    pub(crate) fn new(
        id: u64,
        path: &str,
        text: &str,
        tx: mpsc::UnboundedSender<Msg>,
        scan: Arc<RwLock<Arc<Scan>>>,
    ) -> Self {
        let source = SourceDocument::named(text, path);
        let text = Mutex::new(Text {
            source,
            version: 0,
            closed: false,
        });
        Self(Arc::new(Cell { id, text, tx, scan }))
    }

    pub fn edit(
        &self,
        start: u32,
        length: u32,
        text: &str,
        changing: Option<TextRange>,
        mirroring: bool,
    ) -> Option<Vec<TextEdit>> {
        let mut held = lock(&self.0.text);
        if held.closed {
            return None;
        }
        let mirrors = (held.source).apply_edit(start, length, text, changing, mirroring);
        let edit = TextEdit {
            start,
            length,
            text: text.to_owned(),
        };
        self.edited(&mut held, edit);
        Some(mirrors)
    }

    pub fn restore(&self, text: &str) {
        let mut held = lock(&self.0.text);
        let had = held.source.text();
        if held.closed || had == text {
            return;
        }
        held.source = SourceDocument::named(text, &held.source.path);
        let edit = TextEdit {
            start: 0,
            length: utf16::len(&had) as u32,
            text: text.to_owned(),
        };
        self.edited(&mut held, edit);
    }

    fn edited(&self, held: &mut Text, edit: TextEdit) {
        held.version += 1;
        let (doc, version) = (self.0.id, held.version);
        let _ = self.0.tx.send(Msg::Edited { doc, version, edit });
    }

    pub fn select(&self, selection: TextRange, mirroring: bool) {
        lock(&self.0.text).source.select(selection, mirroring);
        let caret = selection.start as usize;
        let _ = self.0.tx.send(Msg::Selected {
            doc: self.0.id,
            caret,
        });
    }

    pub fn editable(&self) -> bool {
        !lock(&self.0.text).closed
    }

    pub(crate) fn close(&self) {
        lock(&self.0.text).closed = true;
    }

    /// Closes the document only if nothing was typed since `saved`, deciding under the lock an edit takes.
    pub(crate) fn close_if(&self, saved: u64) -> bool {
        let mut held = lock(&self.0.text);
        held.closed |= held.version == saved;
        held.closed
    }

    pub fn with<T>(&self, body: impl FnOnce(&mut SourceDocument) -> T) -> T {
        let symbols = self.symbols();
        let mut held = lock(&self.0.text);
        held.source.set_symbols(symbols);
        body(&mut held.source)
    }

    pub(crate) fn symbols(&self) -> Arc<Symbols> {
        let scan = self.0.scan.read();
        Arc::clone(&scan.unwrap_or_else(PoisonError::into_inner).symbols)
    }

    pub(crate) fn id(&self) -> u64 {
        self.0.id
    }

    pub(crate) fn moved(&self, path: &str) {
        path.clone_into(&mut lock(&self.0.text).source.path);
    }

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_document_closes_only_at_the_version_saved_so_an_edit_since_survives() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let document = Document::new(1, "main.tex", "text", tx, Arc::default());
        assert!(document.edit(0, 0, "typed ", None, false).is_some());
        assert!(!document.close_if(0) && document.editable());
        assert!(document.close_if(1));
        assert!(document.edit(0, 0, "late ", None, false).is_none());
        document.restore("late");
        assert_eq!(document.snapshot(), ("typed text".into(), 1));
    }
}
