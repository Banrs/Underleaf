use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::ffi::OsStr;
use std::fs;
use std::ops::Deref;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError, RwLock};

use notify::event::ModifyKind;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use texlocal_latex::logparse::LogItem;
use texlocal_latex::project::{self, Analysis, Scan};
use tokio::sync::mpsc;

use super::Msg;
use super::actor::{Core, Timer};
use super::documents::Docs;
use super::scans::texts;
use super::state::{ProjectState, SessionSection};
use crate::paths::{Project, disk_spelling, fold_case, relative, within};
use crate::projects::{self, TreeNode, real_path, shown};
use crate::{CoreError, HISTORY_DIR, SETTINGS_FILE, lock, settings, tex};

pub(crate) struct Change {
    pub path: PathBuf,
    pub structural: bool,
}

#[derive(Default)]
pub(crate) struct Tree {
    index: TreeIndex,
    watcher: Option<Watching>,
    pending: Vec<Change>,
    pub scan: Arc<RwLock<Arc<Scan>>>,
    scans: u64,
    pub facts: Arc<projects::Files>,
}

impl Deref for Tree {
    type Target = TreeIndex;

    fn deref(&self) -> &TreeIndex {
        &self.index
    }
}

impl Tree {
    pub fn new(
        project: &Project,
        tree: &[TreeNode],
        tx: Option<mpsc::UnboundedSender<Msg>>,
    ) -> Self {
        let index = TreeIndex::of(tree);
        let watcher = tx.and_then(|tx| watch(project, &index, tx));
        Self {
            index,
            watcher,
            ..Self::default()
        }
    }

    pub fn show(&mut self, cx: &mut Core, tree: Vec<TreeNode>) -> bool {
        self.index = TreeIndex::of(&tree);
        if let Some(watcher) = &mut self.watcher {
            watcher.refresh(&cx.project, &self.index);
        }
        let changed = cx.publish(SessionSection::Tree(tree));
        self.publish_project(cx);
        changed
    }

    pub fn publish_project(&self, cx: &mut Core) {
        let project = ProjectState {
            name: cx.project.name(),
            root: cx.project.root.to_string_lossy().into_owned(),
            settings: settings::shown(&cx.project, self.main.clone()),
            problem: settings::problem(&cx.project),
        };
        cx.publish(SessionSection::Project(project));
    }

    pub fn changed(&mut self, cx: &mut Core, changes: Vec<Change>) {
        self.pending.extend(changes);
        cx.soon(Timer::Fs);
    }

    /// What the changes on disk since the last mean, refreshing the watcher for a link replaced in place.
    pub fn take_changes(&mut self, cx: &Core, docs: &[String]) -> Meaning {
        let changes = std::mem::take(&mut self.pending);
        let meaning = classify(&cx.project, &changes, &self.index, docs);
        if !meaning.tree
            && changes
                .iter()
                .any(|change| change.structural && change.path.is_symlink())
            && let Some(watcher) = &mut self.watcher
        {
            watcher.refresh(&cx.project, &self.index);
        }
        meaning
    }

    pub fn scan(&mut self, cx: &Core, docs: &Docs, edits: u64) {
        self.scans += 1;
        let (seq, project, tx) = (self.scans, cx.project.clone(), cx.tx.clone());
        let (shown, facts) = (docs.open.clone(), Arc::clone(&self.facts));
        let docs = docs.handles();
        let mut files: Vec<String> = self.files.iter().cloned().collect();
        files.sort_unstable();
        let (service, main) = (Arc::clone(&cx.service), self.main.clone());
        tokio::task::spawn_blocking(move || {
            let read = projects::scan_facts(&project, &facts, &texts(&docs));
            let installed = tex::installed(&service.tool_paths().0);
            let result = read.map(|read| {
                let scan = Scan::new(read, files, installed);
                let checks = main
                    .as_deref()
                    .map_or_else(Vec::new, |main| project::check(&scan, main));
                let analysis = project::analyze(&scan, main.as_deref(), shown.as_deref());
                Box::new((scan, checks, analysis))
            });
            let _ = tx.send(Msg::Symbols { seq, edits, result });
        });
    }

    pub fn scanned(
        &self,
        seq: u64,
        result: Result<Box<(Scan, Vec<LogItem>, Analysis)>, CoreError>,
    ) -> Option<(Vec<LogItem>, Analysis)> {
        let (scan, checks, outline) = *result.ok().filter(|_| seq == self.scans)?;
        *self.scan.write().unwrap_or_else(PoisonError::into_inner) = Arc::new(scan);
        Some((checks, outline))
    }
}

pub(crate) struct Watching {
    watcher: RecommendedWatcher,
    paths: BTreeMap<PathBuf, bool>,
    links: Arc<Mutex<BTreeMap<PathBuf, PathBuf>>>,
}

pub(crate) fn watch(
    project: &Project,
    index: &TreeIndex,
    tx: mpsc::UnboundedSender<Msg>,
) -> Option<Watching> {
    let base = project.clone();
    let links = Arc::new(Mutex::new(BTreeMap::new()));
    let aliases = Arc::clone(&links);
    let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let changes = match event {
            Ok(event) if !event.need_rescan() => changes(event, &base, &lock(&aliases)),
            _ => vec![Change {
                path: base.root.clone(),
                structural: true,
            }],
        };
        if !changes.is_empty() {
            let _ = tx.send(Msg::Fs(changes));
        }
    })
    .ok()?;
    let mut watching = Watching {
        watcher,
        paths: BTreeMap::new(),
        links,
    };
    watching.refresh(project, index);
    watching
        .paths
        .contains_key(&project.root)
        .then_some(watching)
}

impl Watching {
    pub fn refresh(&mut self, project: &Project, index: &TreeIndex) {
        let links = linked(project, index);
        let mut paths = BTreeMap::from([(project.root.clone(), true)]);
        for target in links
            .values()
            .filter(|target| !target.starts_with(&project.root))
        {
            if target.exists() {
                paths.insert(target.clone(), true);
            }
            // A parent watch survives an atomic replacement or removal of the target itself.
            if let Some(parent) = target.ancestors().skip(1).find(|parent| parent.is_dir()) {
                paths.entry(parent.to_owned()).or_insert(false);
            }
        }
        *lock(&self.links) = links;
        for (path, recursive) in &paths {
            if self.paths.get(path) == Some(recursive) {
                continue;
            }
            if self.paths.remove(path).is_some() {
                let _ = self.watcher.unwatch(path);
            }
            let mode = if *recursive {
                RecursiveMode::Recursive
            } else {
                RecursiveMode::NonRecursive
            };
            if self.watcher.watch(path, mode).is_ok() {
                self.paths.insert(path.clone(), *recursive);
            }
        }
        let removed: Vec<_> = self
            .paths
            .keys()
            .filter(|path| !paths.contains_key(*path))
            .cloned()
            .collect();
        for path in removed {
            let _ = self.watcher.unwatch(&path);
            self.paths.remove(&path);
        }
    }
}

fn linked(project: &Project, index: &TreeIndex) -> BTreeMap<PathBuf, PathBuf> {
    let mut links = BTreeMap::new();
    let folders = std::iter::once("").chain(index.folders.iter().map(String::as_str));
    for folder in folders {
        let Ok(entries) = fs::read_dir(project.root.join(folder)) else {
            continue;
        };
        for entry in entries.flatten() {
            if !entry.file_type().is_ok_and(|kind| kind.is_symlink()) {
                continue;
            }
            let path = entry.path();
            let Some(rel) = relative(&project.root, &path) else {
                continue;
            };
            if !shown(project, &rel) || !index.contains(&rel) && path.exists() {
                continue;
            }
            if let Ok(target) = fs::read_link(&path) {
                let target = path
                    .parent()
                    .expect("a directory entry has a parent")
                    .join(target);
                links.insert(path, real_path(&target));
            }
        }
    }
    links
}

fn changes(
    event: notify::Event,
    project: &Project,
    links: &BTreeMap<PathBuf, PathBuf>,
) -> Vec<Change> {
    let structural = match event.kind {
        EventKind::Access(_) => return Vec::new(),
        EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(ModifyKind::Name(_)) => {
            true
        }
        _ => false,
    };
    let mut paths = BTreeSet::new();
    for path in event.paths {
        if path.starts_with(&project.root) {
            paths.insert(path.clone());
        }
        for (alias, target) in links {
            if let Ok(rest) = path.strip_prefix(target) {
                paths.insert(alias.join(rest));
            } else if structural && target.starts_with(&path) {
                paths.insert(alias.clone());
            }
        }
    }
    let ours = |path: &PathBuf| {
        let top = path
            .strip_prefix(&project.root)
            .ok()
            .and_then(|rest| rest.iter().next());
        top.and_then(OsStr::to_str)
            .is_some_and(|top| project.builds_in(top) || top == HISTORY_DIR)
    };
    paths
        .into_iter()
        .filter(|path| !ours(path))
        .map(|path| Change { path, structural })
        .collect()
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
    project: &Project,
    changes: &[Change],
    index: &TreeIndex,
    docs: &[String],
) -> Meaning {
    let mut meaning = Meaning::default();
    for change in changes {
        let Some(rel) = relative(&project.root, &change.path) else {
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
        if change.structural && shown_folder && !listed_as_before(project, &rel, index) {
            meaning.tree = true;
        }
        meaning.settings |= fold_case(&rel) == SETTINGS_FILE;
        if change.structural && index.folders.contains(&rel) {
            meaning.listed.extend(
                index
                    .files
                    .iter()
                    .filter(|file| within(file, &rel))
                    .cloned(),
            );
        }
        if index.contains(&rel) {
            meaning.listed.insert(rel);
        }
    }
    meaning
}

fn listed_as_before(project: &Project, rel: &str, index: &TreeIndex) -> bool {
    !shown(project, rel)
        || index.files.contains(rel) && disk_spelling(&project.root, rel).as_deref() == Some(rel)
}
