use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

struct Edit {
    path: String,
    offset: usize,
    remove: usize,
    text: String,
}

/// The engine counts each open/change it reads. Keep edits until an output acknowledges them;
/// taking the latest outbound text would label an older SyncTeX with newer line numbers.
#[derive(Default)]
pub(super) struct Sources {
    pub current: HashMap<String, String>,
    typeset: HashMap<String, String>,
    revision: u64,
    pending: VecDeque<Edit>,
}

impl Sources {
    pub fn changed(&mut self, path: &str, offset: usize, remove: usize, text: &str) {
        self.pending.push_back(Edit {
            path: path.into(),
            offset,
            remove,
            text: text.into(),
        });
    }

    pub fn acknowledge(&mut self, revision: u64) -> Option<()> {
        let count = usize::try_from(revision.checked_sub(self.revision)?).ok()?;
        if count > self.pending.len() {
            return None;
        }
        for edit in self.pending.drain(..count) {
            self.typeset
                .entry(edit.path)
                .or_default()
                .replace_range(edit.offset..edit.offset + edit.remove, &edit.text);
        }
        self.revision = revision;
        Some(())
    }

    pub fn typeset(&mut self, revision: u64) -> Option<HashMap<String, Arc<str>>> {
        self.acknowledge(revision)?;
        Some(
            self.typeset
                .iter()
                .map(|(path, text)| (path.clone(), Arc::from(text.as_str())))
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_outputs_acknowledge_only_their_edits_and_cannot_mutate_an_earlier_snapshot() {
        let mut sources = Sources::default();
        sources.changed("main.tex", 0, 0, "a🔎\nb");
        sources.changed("part.tex", 0, 0, "part");
        sources.changed("main.tex", 1, 4, "\n");
        let first = sources.typeset(1).unwrap();
        assert_eq!(&*first["main.tex"], "a🔎\nb");
        assert!(!first.contains_key("part.tex"));
        let next = sources.typeset(2).unwrap();
        assert_eq!(&*next["main.tex"], "a🔎\nb");
        assert_eq!(&*next["part.tex"], "part");
        assert!(sources.typeset(1).is_none());
        assert!(sources.typeset(4).is_none());
        assert_eq!(sources.typeset(2).unwrap(), next);
        sources.acknowledge(3).unwrap();
        assert!(sources.pending.is_empty());
        assert_eq!(&*sources.typeset(3).unwrap()["main.tex"], "a\n\nb");
        assert_eq!(&*first["main.tex"], "a🔎\nb");
        assert!(sources.pending.is_empty());
    }
}
