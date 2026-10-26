use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};

use notify::event::ModifyKind;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::mpsc;

use super::Msg;
use crate::SETTINGS_FILE;
use crate::analyze::disk_spelling;
use crate::paths::{fold_case, within};
use crate::projects::{TreeNode, listed};

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

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Meaning {
    pub tree: bool,
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
