use std::sync::{Arc, Mutex, PoisonError, RwLock};

use texlocal_latex::facts::Facts;
use texlocal_latex::file_kind;
use texlocal_latex::project::Scan;
use texlocal_latex::syntax::{SourceDocument, Symbols, TextEdit, TextRange};
use texlocal_latex::utf16;
use tokio::sync::mpsc;

use super::Msg;
use crate::lock;

struct Text {
    source: SourceDocument,
    version: u64,
    closed: bool,
    behind: bool,
    recovered: bool,
}

impl Text {
    fn editable(&self) -> bool {
        !self.closed && !self.behind
    }
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
            behind: false,
            recovered: false,
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
        if !held.editable() {
            return None;
        }
        let mirrors = (held.source).apply_edit(start, length, text, changing, mirroring);
        let edit = TextEdit {
            start,
            length,
            text: text.to_owned(),
        };
        self.changed(&mut held, edit);
        Some(mirrors)
    }

    pub fn restore(&self, text: &str) {
        let mut held = lock(&self.0.text);
        if held.closed {
            return;
        }
        let had = held.source.text();
        held.source = SourceDocument::named(text, &held.source.path);
        let behind = std::mem::take(&mut held.behind);
        if had != text {
            held.recovered |= behind;
            let edit = TextEdit {
                start: 0,
                length: utf16::len(&had) as u32,
                text: text.to_owned(),
            };
            self.changed(&mut held, edit);
        }
    }

    pub(crate) fn reload(&self, text: &str, seen: u64) -> Option<u64> {
        let mut held = lock(&self.0.text);
        if held.version != seen {
            return None;
        }
        held.source = SourceDocument::named(text, &held.source.path);
        held.version += 1;
        held.behind = true;
        Some(held.version)
    }

    fn changed(&self, held: &mut Text, edit: TextEdit) {
        held.version += 1;
        let (doc, version) = (self.0.id, held.version);
        let _ = self.0.tx.send(Msg::Changed {
            doc,
            version,
            edit,
            recovered: held.recovered,
        });
    }

    pub(crate) fn shown(&self) {
        let mut held = lock(&self.0.text);
        held.source.reset_typing();
        held.behind = false;
    }

    pub fn editable(&self) -> bool {
        lock(&self.0.text).editable()
    }

    pub(crate) fn close(&self) {
        lock(&self.0.text).closed = true;
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

    pub(crate) fn save_snapshot(&self) -> Option<(String, u64)> {
        let held = lock(&self.0.text);
        // Recovery can beat the actor's Changed message; never save it over the external text before resolution.
        (!held.recovered).then(|| (held.source.text(), held.version))
    }

    pub(crate) fn resolved(&self) {
        lock(&self.0.text).recovered = false;
    }

    pub fn version(&self) -> u64 {
        lock(&self.0.text).version
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_blocks_saving_even_before_the_actor_reads_its_message() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let document = Document::new(1, "main.tex", "original", tx, Arc::default());
        assert_eq!(document.reload("external", 0), Some(1));
        assert!(document.edit(0, 0, "accepted ", None, false).is_none());
        document.restore("accepted original");
        assert!(document.editable());
        assert_eq!(document.snapshot(), ("accepted original".into(), 2));
        assert_eq!(document.save_snapshot(), None);
        document.resolved();
        assert_eq!(
            document.save_snapshot(),
            Some(("accepted original".into(), 2))
        );
        document.close();
        document.restore("late");
        assert_eq!(document.snapshot().0, "accepted original");
    }
}
