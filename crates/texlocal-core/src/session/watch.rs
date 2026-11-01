use std::collections::{BTreeSet, HashSet};
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use notify::event::ModifyKind;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::mpsc;

use super::Msg;
use crate::paths::{disk_spelling, fold_case, in_build_dir, relative, within};
use crate::projects::{TreeNode, listed};
use crate::{HISTORY_DIR, SETTINGS_FILE};

pub(crate) struct Change {
    pub path: PathBuf,
    pub structural: bool,
}

pub(crate) fn watch(root: &Path, tx: mpsc::UnboundedSender<Msg>) -> Option<RecommendedWatcher> {
    let base = root.to_path_buf();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let changes = match event {
            Ok(event) if !event.need_rescan() => changes(event, &base),
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

fn changes(event: notify::Event, root: &Path) -> Vec<Change> {
    let structural = match event.kind {
        EventKind::Access(_) => return Vec::new(),
        EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(ModifyKind::Name(_)) => {
            true
        }
        _ => false,
    };
    let ours = |path: &PathBuf| {
        let top = path
            .strip_prefix(root)
            .ok()
            .and_then(|rest| rest.iter().next());
        top.and_then(OsStr::to_str)
            .is_some_and(|top| in_build_dir(top) || top == HISTORY_DIR)
    };
    let paths = event.paths.into_iter().filter(|path| !ours(path));
    paths.map(|path| Change { path, structural }).collect()
}

#[derive(Default)]
pub(crate) struct TreeIndex {
    pub files: HashSet<String>,
    pub folders: HashSet<String>,
    pub main: Option<String>,
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

#[derive(Default)]
pub(crate) struct Meaning {
    pub tree: bool,
    pub settings: bool,
    pub docs: BTreeSet<String>,
    pub listed: BTreeSet<String>,
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
            if change.structural {
                meaning.tree = true;
                meaning.settings = true;
                meaning.docs.extend(docs.iter().cloned());
                meaning.listed.extend(index.files.iter().cloned());
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
        meaning.settings |= fold_case(&rel) == SETTINGS_FILE;
        if index.contains(&rel) {
            meaning.listed.insert(rel);
        }
    }
    meaning
}

fn listed_as_before(root: &Path, rel: &str, index: &TreeIndex) -> bool {
    !listed(rel) || index.files.contains(rel) && disk_spelling(root, rel).as_deref() == Some(rel)
}
