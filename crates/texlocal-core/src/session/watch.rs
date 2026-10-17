//! The project folder's watcher (FSEvents or ReadDirectoryChangesW, through
//! `notify`), and what its changes mean to a session: the listed tree changed,
//! or a file changed in place.

use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use notify::event::ModifyKind;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::mpsc;

use super::Msg;
use crate::paths::within;
use crate::projects::TreeNode;

/// A path the system said changed. Structural: made, removed or renamed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Change {
    pub path: PathBuf,
    pub structural: bool,
}

/// Watches `root` and its folders, sending what changes to the session.
pub(crate) fn watch(root: &Path, tx: mpsc::UnboundedSender<Msg>) -> Option<RecommendedWatcher> {
    let base = root.to_path_buf();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let (paths, structural) = match event {
            Ok(event) if !event.need_rescan() => match event.kind {
                EventKind::Access(_) => return,
                EventKind::Create(_)
                | EventKind::Remove(_)
                | EventKind::Modify(ModifyKind::Name(_)) => (event.paths, true),
                _ => (event.paths, false),
            },
            // Changes may have been lost: the whole folder is looked at again.
            _ => (vec![base.clone()], true),
        };
        let changes: Vec<Change> = paths
            .into_iter()
            .map(|path| Change { path, structural })
            .collect();
        if !changes.is_empty() {
            let _ = tx.send(Msg::Fs(changes));
        }
    })
    .ok()?;
    watcher.watch(root, RecursiveMode::Recursive).ok()?;
    Some(watcher)
}

/// The project's entries as last listed (`projects::file_tree`).
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct TreeIndex {
    files: HashSet<String>,
    folders: HashSet<String>,
}

impl TreeIndex {
    pub fn of(tree: &[TreeNode]) -> Self {
        fn add(index: &mut TreeIndex, nodes: &[TreeNode]) {
            for node in nodes {
                if let Some(children) = &node.children {
                    index.folders.insert(node.path.clone());
                    add(index, children);
                } else {
                    index.files.insert(node.path.clone());
                }
            }
        }
        let mut index = Self::default();
        add(&mut index, tree);
        index
    }

    pub fn contains(&self, path: &str) -> bool {
        self.files.contains(path) || self.folders.contains(path)
    }
}

/// What a batch of changes means to the session.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Meaning {
    /// The listing may differ: read the tree again.
    pub tree: bool,
    /// Open documents whose file may have changed on disk.
    pub docs: BTreeSet<String>,
    /// Listed entries that changed.
    pub listed: BTreeSet<String>,
}

pub(crate) fn classify(
    root: &Path,
    changes: &[Change],
    index: &TreeIndex,
    docs: &[&str],
) -> Meaning {
    let mut meaning = Meaning::default();
    for change in changes {
        let Some(rel) = relative(root, &change.path) else {
            continue;
        };
        if rel.is_empty() {
            // The folder itself moved, or the system lost count of it: any
            // file in it may have changed unseen.
            if change.structural {
                meaning.tree = true;
                meaning.docs.extend(docs.iter().map(ToString::to_string));
            }
            continue;
        }
        let touched = docs
            .iter()
            .filter(|doc| **doc == rel || change.structural && within(doc, &rel));
        meaning.docs.extend(touched.map(ToString::to_string));
        let parent = rel.rsplit_once('/').map_or("", |(parent, _)| parent);
        let shown_folder = parent.is_empty() || index.folders.contains(parent);
        if change.structural && shown_folder && !listed_as_before(root, &rel, index) {
            meaning.tree = true;
        }
        if index.contains(&rel) {
            meaning.listed.insert(rel);
        }
    }
    meaning
}

/// `root`'s path for `path`, with forward slashes; "" for the root itself.
fn relative(root: &Path, path: &Path) -> Option<String> {
    let rest = path.strip_prefix(root).ok()?;
    let parts: Option<Vec<&str>> = rest.components().map(|c| c.as_os_str().to_str()).collect();
    Some(parts?.join("/"))
}

/// A save, the session's or another app's, renames a new file over a listed
/// one, which leaves the listing as it was; nor does the tree list a hidden
/// file. A rename that changes only case leaves a file at the old spelling on
/// a volume that ignores case, so the file must be there spelt as listed.
fn listed_as_before(root: &Path, rel: &str, index: &TreeIndex) -> bool {
    let path = root.join(rel);
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return false;
    };
    name.to_string_lossy().starts_with('.')
        || index.files.contains(rel)
            && fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file())
            && fs::read_dir(parent).is_ok_and(|mut entries| {
                entries.any(|entry| entry.is_ok_and(|entry| entry.file_name() == name))
            })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index(files: &[&str], folders: &[&str]) -> TreeIndex {
        let set = |paths: &[&str]| paths.iter().map(ToString::to_string).collect();
        TreeIndex {
            files: set(files),
            folders: set(folders),
        }
    }

    fn change(root: &Path, rel: &str, structural: bool) -> Change {
        let path = root.join(rel);
        Change { path, structural }
    }

    fn set(paths: &[&str]) -> BTreeSet<String> {
        paths.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn a_save_renamed_over_a_listed_file_changes_its_content_not_the_tree() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::write(root.join("main.tex"), "x").unwrap();
        let changes = [
            change(root, ".texlocal-abc", true),
            change(root, "main.tex", true),
            change(root, "main.tex", false),
        ];
        let meaning = classify(root, &changes, &index(&["main.tex"], &[]), &["main.tex"]);
        let expected = Meaning {
            tree: false,
            docs: set(&["main.tex"]),
            listed: set(&["main.tex"]),
        };
        assert_eq!(meaning, expected);
    }

    #[test]
    fn new_gone_and_recased_entries_change_the_tree_and_unlisted_folders_dont() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("build")).unwrap();
        fs::write(root.join("Main.tex"), "x").unwrap();
        let index = index(&["main.tex", "gone.tex"], &["fig"]);
        let tree = |rel: &str| classify(root, &[change(root, rel, true)], &index, &[]).tree;
        assert!(tree("new.tex") && tree("gone.tex") && tree("fig/plot.pdf"));
        // Renamed in case only: the old spelling is no longer the disk's.
        assert!(tree("main.tex"));
        assert!(!tree("build/main.aux") && !tree("unlisted/deep.tex"));
        let content = classify(root, &[change(root, "new.tex", false)], &index, &[]);
        assert_eq!(content, Meaning::default());
    }

    #[test]
    fn a_moved_folder_or_root_reaches_the_documents_inside_it() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let index = index(&["ch/one.tex", "main.tex"], &["ch"]);
        let docs = ["ch/one.tex", "main.tex"];
        let of = |rel: &str| classify(root, &[change(root, rel, true)], &index, &docs);
        let moved = of("ch");
        assert!(moved.tree);
        assert_eq!(moved.docs, set(&["ch/one.tex"]));
        let lost = of("");
        assert!(lost.tree && lost.docs == set(&docs));
        // A file that only starts like the folder's name isn't in it.
        assert!(of("c").docs.is_empty());
        let elsewhere = change(root.parent().unwrap(), "other", true);
        assert_eq!(
            classify(root, &[elsewhere], &index, &docs),
            Meaning::default()
        );
    }
}
