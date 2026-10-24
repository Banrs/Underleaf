//! The project's history as the session keeps it: a snapshot as it opens and after saves, one
//! before each change across files, and the commands that list, compare and restore them.

use std::fs;
use std::io::ErrorKind;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::{Value, json};

use super::Reply;
use super::actor::Actor;
use crate::paths::RelPath;
use crate::projects::{self, History, Taken};
use crate::service::out;
use crate::syntax::TextEdit;
use crate::texpresso::delta;
use crate::{CoreError, lf, lock, lossy_string};

fn now() -> i64 {
    let since = SystemTime::now().duration_since(UNIX_EPOCH);
    since.map_or(0, |since| since.as_millis() as i64)
}

impl Actor {
    /// As the session opens, so the files as they were before its edits are kept, and after each
    /// save; beside the session, so no save waits on the store.
    pub fn snapshot_soon(&self) {
        let (history, root) = (Arc::clone(&self.history), self.project.root.clone());
        tokio::task::spawn_blocking(move || lock(&history).take(&root, now(), Taken::Auto));
    }

    /// On the session's task, as the change waits for it: its id.
    pub fn snapshot_before(&self, reason: &'static str) -> Result<Option<String>, CoreError> {
        let taken = lock(&self.history).take(&self.project.root, now(), Taken::Before(reason))?;
        Ok(taken.map(|id| id.to_string()))
    }

    /// List, save and compare read the store but change no file of the project's, so they
    /// answer from beside the session.
    fn beside(
        &self,
        job: impl FnOnce(&History) -> Result<Value, CoreError> + Send + 'static,
        reply: Reply,
    ) {
        let history = Arc::clone(&self.history);
        tokio::task::spawn_blocking(move || reply.send(job(&lock(&history))));
    }

    pub fn history_list(&self, reply: Reply) {
        self.beside(|history| out(history.list()?), reply);
    }

    pub fn history_save(&self, name: String, reply: Reply) {
        let name = name.trim().to_owned();
        if name.is_empty() {
            return reply.send(Err(CoreError::bad_request("A version needs a name.")));
        }
        let root = self.project.root.clone();
        let save = move |history: &History| {
            history.take(&root, now(), Taken::Named(name))?;
            out(history.list()?.first())
        };
        self.beside(save, reply);
    }

    pub fn history_compare(&self, id: String, path: String, reply: Reply) {
        if !projects::is_text(&path) {
            let refused = CoreError::bad_request("Only a text file can be compared.");
            return reply.send(Err(refused));
        }
        let edited = self.docs.get(&path).map(|doc| doc.doc.snapshot().0);
        let abs = self.project.root.join(&path);
        let compared = move |history: &History| {
            let text = |bytes| lf(lossy_string(bytes));
            let old = history.files(&id, |p| p == path)?.pop();
            let new = match (edited, fs::read(abs)) {
                (Some(edited), _) => edited,
                (None, Err(err)) if err.kind() == ErrorKind::NotFound => String::new(),
                (None, read) => text(read?),
            };
            out(compare(
                &old.map_or(String::new(), |(_, bytes)| text(bytes)),
                &new,
            ))
        };
        self.beside(compared, reply);
    }

    /// The snapshot's files, or those of them `paths` names, as they were: an open document's as
    /// edits, the others written, all or none, as a replace does.
    pub fn history_restore(
        &mut self,
        id: &str,
        paths: Option<Vec<RelPath>>,
    ) -> Result<Value, CoreError> {
        let open = self.texts_to_edit("restored")?;
        let chosen = |path: &str| {
            paths
                .as_ref()
                .is_none_or(|paths| paths.iter().any(|p| p.0 == path))
        };
        let files = lock(&self.history).files(id, chosen)?;
        let (mut edits, mut others) = (Vec::new(), Vec::new());
        for (path, bytes) in files {
            match open.iter().find(|(open, ..)| *open == path) {
                Some((_, text, version)) => {
                    if let Some(edit) = edit_to(text, &lf(lossy_string(bytes))) {
                        edits.push(json!({ "path": path, "version": version, "edits": [edit] }));
                    }
                }
                None if !self.deleting(&path) => others.push((path, bytes)),
                None => {}
            }
        }
        if edits.len() > 1 {
            return Err(CoreError::conflict(super::actor::ONE_DOCUMENT));
        }
        self.snapshot_before("Before Restore")?;
        let written = self.service.with_project(&self.project_id, |project| {
            projects::put_back(&project.root, others)
        })?;
        if !written.is_empty() {
            self.reload_tree();
        }
        Ok(json!({ "edits": edits.pop() }))
    }
}

/// A line of a comparison: in both texts, the snapshot's alone or now's alone; or a run of lines in
/// both further than `CONTEXT` from any change, folded as a unified diff's hunks leave them out.
#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
enum Row<'a> {
    Same(&'a str),
    Removed(&'a str),
    Added(&'a str),
    Skipped(usize),
}

const CONTEXT: usize = 3;

/// The snapshot's lines against now's over their longest common subsequence, removed before added
/// where a block was replaced; none where the lines are the same. The common start and end, which
/// most edits leave, are set aside first so the table is the middle's, and a middle too big for one
/// shows as removed then added.
fn compare<'a>(old: &'a str, new: &'a str) -> Vec<Row<'a>> {
    let (a, b): (Vec<_>, Vec<_>) = (old.lines().collect(), new.lines().collect());
    let head = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let ends = a[head..].iter().rev().zip(b[head..].iter().rev());
    let tail = ends.take_while(|(x, y)| x == y).count();
    let (x, y) = (&a[head..a.len() - tail], &b[head..b.len() - tail]);
    let mut rows: Vec<Row> = a[..head].iter().map(|line| Row::Same(line)).collect();
    if x.len() * y.len() > 4_000_000 {
        rows.extend(x.iter().map(|line| Row::Removed(line)));
        rows.extend(y.iter().map(|line| Row::Added(line)));
    } else {
        // `common[i * w + j]`: the longest common subsequence of x[i..] and y[j..].
        let w = y.len() + 1;
        let mut common = vec![0u32; (x.len() + 1) * w];
        for i in (0..x.len()).rev() {
            for j in (0..y.len()).rev() {
                common[i * w + j] = if x[i] == y[j] {
                    common[(i + 1) * w + j + 1] + 1
                } else {
                    common[(i + 1) * w + j].max(common[i * w + j + 1])
                };
            }
        }
        let (mut i, mut j) = (0, 0);
        while i < x.len() || j < y.len() {
            if i < x.len() && j < y.len() && x[i] == y[j] {
                rows.push(Row::Same(x[i]));
                (i, j) = (i + 1, j + 1);
            } else if j == y.len()
                || i < x.len() && common[(i + 1) * w + j] >= common[i * w + j + 1]
            {
                rows.push(Row::Removed(x[i]));
                i += 1;
            } else {
                rows.push(Row::Added(y[j]));
                j += 1;
            }
        }
    }
    rows.extend(a[a.len() - tail..].iter().map(|line| Row::Same(line)));

    let mut shown = vec![false; rows.len()];
    for (i, row) in rows.iter().enumerate() {
        if !matches!(row, Row::Same(_)) {
            shown[i.saturating_sub(CONTEXT)..rows.len().min(i + CONTEXT + 1)].fill(true);
        }
    }
    if !shown.contains(&true) {
        return vec![];
    }
    let mut folded = Vec::new();
    for (row, shown) in rows.into_iter().zip(shown) {
        match (shown, folded.last_mut()) {
            (true, _) => folded.push(row),
            (false, Some(Row::Skipped(count))) => *count += 1,
            (false, _) => folded.push(Row::Skipped(1)),
        }
    }
    folded
}

/// One edit making `text` into `to`, in UTF-16 units, so the editor keeps its place around it.
fn edit_to(text: &str, to: &str) -> Option<TextEdit> {
    if text == to {
        return None;
    }
    let (start, length, inserted) = delta(text, to);
    let units = |s: &str| s.encode_utf16().count() as u32;
    Some(TextEdit {
        start: units(&text[..start]),
        length: units(&text[start..start + length]),
        text: inserted.to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::Row::*;
    use super::compare;

    #[test]
    fn a_comparison_folds_lines_far_from_a_change_and_puts_removed_before_added() {
        let old = "1\n2\n3\n4\n5\n6\n7\n8\nold\n9\n10\n11\n12\n";
        let new = "0\n1\n2\n3\n4\n5\n6\n7\n8\nnew\n9\n10\n11\n12";
        let rows = [
            Added("0"),
            Same("1"),
            Same("2"),
            Same("3"),
            Skipped(2),
            Same("6"),
            Same("7"),
            Same("8"),
            Removed("old"),
            Added("new"),
            Same("9"),
            Same("10"),
            Same("11"),
            Skipped(1),
        ];
        assert_eq!(compare(old, new), rows);
        assert_eq!(compare("a\n", "a"), []);
    }
}
