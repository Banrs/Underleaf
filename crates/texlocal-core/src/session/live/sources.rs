use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use texlocal_latex::diff::delta;
use texlocal_latex::syntax::TextEdit;
use texlocal_latex::utf16::byte_offset;

use crate::texpresso::LiveRun;

struct Change {
    path: String,
    offset: usize,
    remove: usize,
    text: String,
}

/// The text TeXpresso was sent and has acknowledged, in bytes. A viewport can acknowledge edits
/// before a whole PDF arrives, so Live keeps that PDF's source snapshot separately.
#[derive(Default)]
pub(super) struct Sources {
    sent: HashMap<String, String>,
    pub read: HashMap<String, Arc<str>>,
    acknowledged: u64,
    unread: VecDeque<Change>,
}

impl Sources {
    pub fn send(&mut self, run: &dyn LiveRun, path: &str, text: &str) {
        let Some(sent) = self.sent.get(path) else {
            run.open(path, text);
            self.sent.insert(path.to_owned(), text.to_owned());
            return self.unread.push_back(Change {
                path: path.to_owned(),
                offset: 0,
                remove: 0,
                text: text.to_owned(),
            });
        };
        let (offset, remove, inserted) = delta(sent, text);
        if remove > 0 || !inserted.is_empty() {
            self.change(run, path, offset, remove, inserted);
        }
    }

    /// Sends an edit given in UTF-16 units; false when it doesn't fit the text sent, as in a file not sent.
    pub fn edit(&mut self, run: &dyn LiveRun, path: &str, edit: &TextEdit) -> bool {
        let fits = self.sent.get(path).and_then(|sent| {
            let offset = byte_offset(sent, edit.start as usize)?;
            Some((offset, byte_offset(&sent[offset..], edit.length as usize)?))
        });
        let Some((offset, remove)) = fits else {
            return false;
        };
        self.change(run, path, offset, remove, &edit.text);
        true
    }

    fn change(&mut self, run: &dyn LiveRun, path: &str, offset: usize, remove: usize, text: &str) {
        let sent = self.sent.get_mut(path).expect("sent");
        sent.replace_range(offset..offset + remove, text);
        run.change(path, offset, remove, text);
        self.unread.push_back(Change {
            path: path.to_owned(),
            offset,
            remove,
            text: text.to_owned(),
        });
    }

    /// Sends the caret, given in UTF-16 units; false when its file wasn't sent.
    pub fn caret(&self, run: &dyn LiveRun, path: &str, units: usize) -> bool {
        let offset = self
            .sent
            .get(path)
            .and_then(|text| byte_offset(text, units));
        offset.inspect(|&offset| run.caret(path, offset)).is_some()
    }

    /// Takes the changes an output says TeXpresso read into the acknowledged text, rebuilding only the files
    /// they touch; None when it claims more than was sent or less than an earlier output.
    pub fn acknowledge(&mut self, revision: u64) -> Option<()> {
        let count = usize::try_from(revision.checked_sub(self.acknowledged)?).ok()?;
        if count > self.unread.len() {
            return None;
        }
        let mut changed: HashMap<String, String> = HashMap::new();
        for change in self.unread.drain(..count) {
            let read = |path: &String| self.read.get(path).map(ToString::to_string);
            let text = changed
                .entry(change.path)
                .or_insert_with_key(|path| read(path).unwrap_or_default());
            text.replace_range(change.offset..change.offset + change.remove, &change.text);
        }
        let changed = changed
            .into_iter()
            .map(|(path, text)| (path, Arc::from(text)));
        self.read.extend(changed);
        self.acknowledged = revision;
        Some(())
    }

    /// The count of opens and changes sent, which TeXpresso names once it has read them.
    pub fn revision(&self) -> u64 {
        self.acknowledged + self.unread.len() as u64
    }

    pub fn settled(&self) -> bool {
        self.unread.is_empty()
    }

    pub fn paths(&self) -> impl Iterator<Item = &String> {
        self.sent.keys()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    #[derive(Default)]
    struct Heard(Mutex<Vec<String>>);

    impl LiveRun for Heard {
        fn open(&self, rel: &str, text: &str) {
            self.0.lock().unwrap().push(format!("open {rel} {text:?}"));
        }
        fn change(&self, rel: &str, offset: usize, remove: usize, text: &str) {
            let heard = format!("change {rel} {offset} {remove} {text:?}");
            self.0.lock().unwrap().push(heard);
        }
        fn view(&self, _: u32, _: u32) {}
        fn caret(&self, rel: &str, offset: usize) {
            self.0.lock().unwrap().push(format!("caret {rel} {offset}"));
        }
        fn rescan(&self) {}
        fn mark(&self, _: u64) {}
        fn log(&self) -> String {
            String::new()
        }
        fn tex_log(&self) -> Option<String> {
            None
        }
        fn stop(&self) {}
    }

    fn edit(start: u32, length: u32, text: &str) -> TextEdit {
        let text = text.to_owned();
        TextEdit {
            start,
            length,
            text,
        }
    }

    #[test]
    fn edits_are_sent_in_bytes_and_one_that_does_not_fit_the_text_sent_is_refused() {
        let (run, mut sources) = (Heard::default(), Sources::default());
        assert!(!sources.edit(&run, "main.tex", &edit(0, 0, "a")));
        sources.send(&run, "main.tex", "🔎\nb");
        assert!(sources.edit(&run, "main.tex", &edit(2, 1, "")));
        assert!(!sources.edit(&run, "main.tex", &edit(9, 0, "c")));
        sources.send(&run, "main.tex", "🔎b");
        sources.send(&run, "main.tex", "🔎b!");
        assert!(sources.caret(&run, "main.tex", 2));
        assert!(!sources.caret(&run, "part.tex", 0));
        let heard = [
            r#"open main.tex "🔎\nb""#,
            r#"change main.tex 4 1 """#,
            r#"change main.tex 5 0 "!""#,
            "caret main.tex 4",
        ];
        assert_eq!(*run.0.lock().unwrap(), heard);
        assert_eq!(sources.revision(), 3);
    }

    #[test]
    fn old_outputs_acknowledge_only_their_edits_and_cannot_mutate_an_earlier_snapshot() {
        let (run, mut sources) = (Heard::default(), Sources::default());
        sources.send(&run, "main.tex", "a🔎\nb");
        sources.send(&run, "part.tex", "part");
        assert!(sources.edit(&run, "main.tex", &edit(1, 2, "\n")));
        sources.acknowledge(1).unwrap();
        let first = Arc::clone(&sources.read["main.tex"]);
        assert_eq!(&*first, "a🔎\nb");
        assert!(!sources.read.contains_key("part.tex"));
        sources.acknowledge(2).unwrap();
        assert!(Arc::ptr_eq(&first, &sources.read["main.tex"]));
        assert_eq!(&*sources.read["part.tex"], "part");
        assert!(sources.acknowledge(1).is_none());
        assert!(sources.acknowledge(4).is_none());
        assert!(!sources.settled());
        sources.acknowledge(3).unwrap();
        assert!(sources.settled());
        assert_eq!(&*sources.read["main.tex"], "a\n\nb");
        assert_eq!(&*first, "a🔎\nb");
    }
}
