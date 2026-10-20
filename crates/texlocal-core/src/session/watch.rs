//! The project folder's watcher (through `notify`), and what its changes mean to a
//! session: the listed tree changed, or a file changed in place.

use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};

use notify::event::ModifyKind;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::mpsc;

use super::Msg;
use crate::SETTINGS_FILE;
use crate::analyze::disk_spelling;
use crate::paths::within;
use crate::projects::TreeNode;

#[derive(Debug)]
pub(crate) struct Change {
    pub path: PathBuf,
    pub structural: bool,
}

pub(crate) fn watch(root: &Path, tx: mpsc::UnboundedSender<Msg>) -> Option<RecommendedWatcher> {
    let base = root.to_path_buf();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let changes = match event {
            Ok(event) if !event.need_rescan() => changes(event),
            // Changes may have been lost: the whole folder is looked at again.
            _ => vec![Change {
                path: base.clone(),
                structural: true,
            }],
        };
        if !changes.is_empty() {
            let _ = tx.send(Msg::Fs(changes));
        }
    })
    .ok()?;
    watcher.watch(root, RecursiveMode::Recursive).ok()?;
    Some(watcher)
}

fn changes(event: notify::Event) -> Vec<Change> {
    let structural = match event.kind {
        EventKind::Access(_) => return Vec::new(),
        EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(ModifyKind::Name(_)) => {
            true
        }
        _ => false,
    };
    let paths = event.paths.into_iter();
    paths.map(|path| Change { path, structural }).collect()
}

#[derive(Default, PartialEq, Eq)]
pub(crate) struct TreeIndex {
    pub files: HashSet<String>,
    pub folders: HashSet<String>,
    /// So another main file's mark sends the tree again.
    main: Option<String>,
}

impl TreeIndex {
    pub fn of(tree: &[TreeNode]) -> Self {
        fn add(index: &mut TreeIndex, nodes: &[TreeNode]) {
            for node in nodes {
                match &node.children {
                    Some(children) => {
                        index.folders.insert(node.path.clone());
                        add(index, children);
                    }
                    None => {
                        index.files.insert(node.path.clone());
                        if node.main {
                            index.main = Some(node.path.clone());
                        }
                    }
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

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Meaning {
    pub tree: bool,
    /// The settings changed, perhaps their main file, which the tree marks.
    pub settings: bool,
    pub docs: BTreeSet<String>,
    pub listed: BTreeSet<String>,
}

fn relative(root: &Path, path: &Path) -> Option<String> {
    let rest = path.strip_prefix(root).ok()?;
    let parts: Option<Vec<&str>> = rest.components().map(|c| c.as_os_str().to_str()).collect();
    Some(parts?.join("/"))
}

pub(crate) fn classify(
    root: &Path,
    changes: &[Change],
    index: &TreeIndex,
    docs: &[String],
) -> Meaning {
    let mut meaning = Meaning::default();
    for change in changes {
        let Some(rel) = relative(root, &change.path) else {
            continue;
        };
        if rel.is_empty() {
            // The folder itself moved, or the system lost count: any file may have changed unseen.
            if change.structural {
                meaning.tree = true;
                meaning.docs.extend(docs.iter().cloned());
            }
            continue;
        }
        for doc in docs {
            if *doc == rel || change.structural && within(doc, &rel) {
                meaning.docs.insert(doc.clone());
            }
        }
        let parent = rel.rsplit_once('/').map_or("", |(parent, _)| parent);
        let shown_folder = parent.is_empty() || index.folders.contains(parent);
        if change.structural && shown_folder && !listed_as_before(root, &rel, index) {
            meaning.tree = true;
        }
        meaning.settings |= rel.eq_ignore_ascii_case(SETTINGS_FILE);
        if index.contains(&rel) {
            meaning.listed.insert(rel);
        }
    }
    meaning
}

/// A save renames a new file over a listed one, which leaves the listing as it was; nor
/// does the tree list a hidden file. A rename that changes only case leaves a file at the old
/// spelling on a volume that ignores case.
fn listed_as_before(root: &Path, rel: &str, index: &TreeIndex) -> bool {
    let name = rel.rsplit('/').next().unwrap_or(rel);
    name.starts_with('.')
        || index.files.contains(rel) && disk_spelling(root, rel).as_deref() == Some(rel)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn index(files: &[&str], folders: &[&str]) -> TreeIndex {
        TreeIndex {
            files: files.iter().map(ToString::to_string).collect(),
            folders: folders.iter().map(ToString::to_string).collect(),
            main: None,
        }
    }

    fn change(root: &Path, rel: &str, structural: bool) -> Change {
        let path = root.join(rel);
        Change { path, structural }
    }

    #[test]
    fn a_save_over_a_listed_file_changes_its_content_not_the_tree() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::write(root.join("main.tex"), "x").unwrap();
        let index = index(&["main.tex"], &[]);
        let docs = vec!["main.tex".to_string()];
        let changes = [
            change(root, ".texlocal-abc", true),
            change(root, "main.tex", true),
            change(root, "main.tex", false),
        ];
        let meaning = classify(root, &changes, &index, &docs);
        assert!(!meaning.tree);
        assert_eq!(meaning.docs, BTreeSet::from(["main.tex".to_string()]));
        assert_eq!(meaning.listed, BTreeSet::from(["main.tex".to_string()]));
    }

    #[test]
    fn new_removed_and_recased_files_change_the_tree_but_not_build_output() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("build")).unwrap();
        fs::write(root.join("Main.tex"), "x").unwrap();
        let index = index(&["main.tex", "gone.tex"], &["fig"]);
        let tree = |rel: &str| classify(root, &[change(root, rel, true)], &index, &[]).tree;
        assert!(tree("new.tex"));
        assert!(tree("gone.tex"));
        assert!(tree("fig/plot.pdf"));
        // Renamed in case only: the old spelling is no longer the disk's.
        assert!(tree("main.tex"));
        assert!(!tree("build/main.aux"));
        assert!(!tree("unlisted/deep.tex"));
        let content = classify(root, &[change(root, "new.tex", false)], &index, &[]);
        assert!(!content.tree && content.listed.is_empty());
    }

    #[test]
    fn a_moved_folder_or_root_reaches_the_documents_inside_it() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let index = index(&["ch/one.tex", "main.tex"], &["ch"]);
        let docs = vec!["ch/one.tex".to_string(), "main.tex".to_string()];
        let moved = classify(root, &[change(root, "ch", true)], &index, &docs);
        assert!(moved.tree);
        assert_eq!(moved.docs, BTreeSet::from(["ch/one.tex".to_string()]));
        let rescan = Change {
            path: root.to_path_buf(),
            structural: true,
        };
        let lost = classify(root, &[rescan], &index, &docs);
        assert!(lost.tree && lost.docs.len() == 2);
        // A file that only starts like the folder's name isn't in it.
        let near = classify(root, &[change(root, "c", true)], &index, &docs);
        assert!(near.docs.is_empty());
        let elsewhere = Change {
            path: dir.path().parent().unwrap().join("other"),
            structural: true,
        };
        assert_eq!(
            classify(root, &[elsewhere], &index, &docs),
            Meaning::default()
        );
    }
}
