//! A project's history: snapshots of the files its tree lists, in its `history` folder, which no
//! walk of the project reads. A stored file is named by its contents' hash, so one unchanged
//! since the last snapshot costs nothing. Times are milliseconds since 1970, given by the caller,
//! so the rules are tested without waiting.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::files::{Planned, inside, write_all};
use super::tree::visit_files;
use super::{read_capped, skip_unreadable};
use crate::atomic;
use crate::error::CoreError;
use crate::paths::{Project, safe_write_path};

const MINUTE: i64 = 60_000;
const HOUR: i64 = 60 * MINUTE;
const DAY: i64 = 24 * HOUR;
/// A larger file is data or video, not writing: a copy at each change would fill the disk.
pub(super) const MAX_KEPT: u64 = 20 << 20;

pub(crate) enum Taken {
    /// Only when the last is more than 10 minutes old and something changed since it.
    Auto,
    Before(&'static str),
    /// The author's, which pruning keeps; the last is renamed when nothing changed since it.
    Named(String),
}

/// Stored as `snapshots/<id>.json`, its id its time.
#[derive(Serialize, Deserialize)]
struct Snapshot {
    name: Option<String>,
    reason: Option<String>,
    /// Each file's path and its contents' hash.
    files: BTreeMap<String, String>,
}

#[derive(Debug, Serialize)]
pub(crate) struct Entry {
    id: String,
    /// Milliseconds since 1970, as the id.
    time: i64,
    name: Option<String>,
    reason: Option<String>,
    changed: Vec<Changed>,
}

#[derive(Debug, Serialize)]
struct Changed {
    path: String,
    change: &'static str,
}

/// A store, which a folder keeps when it moves: the root it snapshots is each session's own.
pub(crate) struct History {
    dir: PathBuf,
}

impl History {
    pub fn of(project: &Project) -> Self {
        Self {
            dir: project.history.clone(),
        }
    }

    fn objects(&self) -> PathBuf {
        self.dir.join("objects")
    }

    fn record(&self, id: i64) -> PathBuf {
        self.dir.join("snapshots").join(format!("{id}.json"))
    }

    /// Newest first.
    fn ids(&self) -> Result<Vec<i64>, CoreError> {
        let Some(read) = skip_unreadable(fs::read_dir(self.dir.join("snapshots")))? else {
            return Ok(Vec::new());
        };
        let mut ids = Vec::new();
        for entry in read {
            let name = entry?.file_name();
            let id = name.to_str().and_then(|name| name.strip_suffix(".json"));
            ids.extend(id.and_then(|id| id.parse::<i64>().ok()));
        }
        ids.sort_unstable_by(|a, b| b.cmp(a));
        Ok(ids)
    }

    fn read(&self, id: i64) -> Result<Snapshot, CoreError> {
        let gone = || CoreError::not_found("That version is no longer in the history.");
        let bytes = skip_unreadable(fs::read(self.record(id)))?.ok_or_else(gone)?;
        serde_json::from_slice(&bytes).map_err(|err| CoreError::internal(err.to_string()))
    }

    fn write(&self, id: i64, snapshot: &Snapshot) -> Result<(), CoreError> {
        let record = self.record(id);
        fs::create_dir_all(record.parent().expect("in the snapshots folder"))?;
        let bytes = serde_json::to_vec(snapshot);
        let bytes = bytes.map_err(|err| CoreError::internal(err.to_string()))?;
        atomic::write(&record, &bytes)?;
        Ok(())
    }

    /// Each file the tree lists by its contents' hash, the contents stored unless they are. The
    /// store is made only once the walk has read the folder, so a project deleted after a save
    /// isn't made again by that save's snapshot.
    fn files_now(&self, root: &Path) -> Result<BTreeMap<String, String>, CoreError> {
        let objects = self.objects();
        let mut files = BTreeMap::new();
        visit_files(root, &mut |abs, rel| {
            let Some(bytes) = read_capped(abs, MAX_KEPT)? else {
                return Ok(true);
            };
            let hash: String = Sha256::digest(&bytes)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            let object = objects.join(&hash);
            if !object.exists() {
                fs::create_dir_all(&objects)?;
                atomic::write(&object, &bytes)?;
            }
            files.insert(rel.to_owned(), hash);
            Ok(true)
        })?;
        Ok(files)
    }

    /// One taken as `taken` says, then the history pruned: its id, or None when an automatic one
    /// isn't needed. A record that can't be read is passed over, as it is by the list.
    pub fn take(&self, root: &Path, now: i64, taken: Taken) -> Result<Option<i64>, CoreError> {
        let ids = self.ids()?;
        let latest = ids.iter().find_map(|&id| Some((id, self.read(id).ok()?)));
        // Not one dated later, by a clock once ahead: none would be taken until that time.
        let recent = |(id, _): &(i64, Snapshot)| (0..=10 * MINUTE).contains(&(now - id));
        if matches!(taken, Taken::Auto) && latest.as_ref().is_some_and(recent) {
            return Ok(None);
        }
        let files = self.files_now(root)?;
        let next = ids.first().map_or(now, |id| now.max(id + 1));
        let unchanged = latest.filter(|(_, last)| last.files == files);
        let (id, snapshot) = match (taken, unchanged) {
            (Taken::Auto, Some(_)) => return Ok(None),
            (Taken::Named(name), Some((id, last))) => (
                id,
                Snapshot {
                    name: Some(name),
                    ..last
                },
            ),
            (taken, _) => {
                let (name, reason) = match taken {
                    Taken::Auto => (None, None),
                    Taken::Before(reason) => (None, Some(reason.to_owned())),
                    Taken::Named(name) => (Some(name), None),
                };
                let snapshot = Snapshot {
                    name,
                    reason,
                    files,
                };
                (next, snapshot)
            }
        };
        self.write(id, &snapshot)?;
        self.prune(now);
        Ok(Some(id))
    }

    /// Named snapshots stay; of the others, all from the last day, the last of each hour for a
    /// week and of each day for 90 days. Then the contents no snapshot names go, unless a record
    /// couldn't be read, which may name any. As far as it can: the snapshot is taken already.
    fn prune(&self, now: i64) {
        let Ok(ids) = self.ids() else {
            return;
        };
        let (mut periods, mut used, mut unread) = (HashSet::new(), HashSet::new(), false);
        for id in ids {
            let Ok(snapshot) = self.read(id) else {
                unread = true;
                continue;
            };
            let age = now - id;
            // Newest first, so the first of a period is its last.
            let kept = snapshot.name.is_some()
                || age <= DAY
                || age <= 7 * DAY && periods.insert((HOUR, id / HOUR))
                || age > 7 * DAY && age <= 90 * DAY && periods.insert((DAY, id / DAY));
            // A record that can't be removed stays listed, so its files stay too.
            if kept || fs::remove_file(self.record(id)).is_err() {
                used.extend(snapshot.files.into_values());
            }
        }
        if unread {
            return;
        }
        let Ok(objects) = fs::read_dir(self.objects()) else {
            return;
        };
        for entry in objects.flatten() {
            if !used.contains(entry.file_name().to_string_lossy().as_ref()) {
                let _ = fs::remove_file(entry.path());
            }
        }
    }

    /// Newest first, each with what changed since the one before it.
    pub fn list(&self) -> Result<Vec<Entry>, CoreError> {
        let mut entries = Vec::new();
        let mut before = BTreeMap::new();
        for id in self.ids()?.into_iter().rev() {
            let Ok(snapshot) = self.read(id) else {
                continue;
            };
            entries.push(Entry {
                id: id.to_string(),
                time: id,
                name: snapshot.name,
                reason: snapshot.reason,
                changed: changes(&before, &snapshot.files),
            });
            before = snapshot.files;
        }
        entries.reverse();
        Ok(entries)
    }

    /// The contents of the snapshot's files that `chosen` takes, by path.
    pub fn files(
        &self,
        id: &str,
        chosen: impl Fn(&str) -> bool,
    ) -> Result<Vec<(String, Vec<u8>)>, CoreError> {
        let id = id
            .parse()
            .map_err(|_| CoreError::bad_request("Bad version id"));
        let snapshot = self.read(id?)?;
        let files = snapshot.files.into_iter().filter(|(path, _)| chosen(path));
        let objects = self.objects();
        files
            .map(|(path, hash)| Ok((path, fs::read(objects.join(hash))?)))
            .collect()
    }
}

fn changes(before: &BTreeMap<String, String>, after: &BTreeMap<String, String>) -> Vec<Changed> {
    let paths: BTreeSet<&String> = before.keys().chain(after.keys()).collect();
    let change = |path: &String| match (before.get(path), after.get(path)) {
        (None, _) => Some("added"),
        (_, None) => Some("deleted"),
        (was, now) => (was != now).then_some("changed"),
    };
    let changed = paths.into_iter().filter_map(|path| {
        let change = change(path)?;
        Some(Changed {
            path: path.clone(),
            change,
        })
    });
    changed.collect()
}

/// Files of the project's as they were, written all or none, but those that are so already,
/// those now too large to keep, which the snapshot before couldn't save, and those a link leads
/// out of the project to.
pub(crate) fn put_back(
    root: &Path,
    files: Vec<(String, Vec<u8>)>,
) -> Result<Vec<String>, CoreError> {
    write_all(files, |(rel, bytes)| {
        let abs = safe_write_path(root, &rel)?;
        if !inside(root, &abs) || fs::metadata(&abs).is_ok_and(|meta| meta.len() > MAX_KEPT) {
            return Ok(None);
        }
        let was = match fs::read(&abs) {
            Err(err) if err.kind() == ErrorKind::NotFound => None,
            read => Some(read?),
        };
        let changed = was.as_ref() != Some(&bytes);
        Ok(changed.then_some(Planned {
            abs,
            bytes,
            was,
            done: rel,
        }))
    })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::os::unix::fs::PermissionsExt;

    use super::*;
    use crate::HISTORY_DIR;
    use crate::projects::testing::{names_in, project, with_project, zip_names};
    use crate::projects::{Query, file_tree, is_text, search_project};
    use crate::zipexport::export_zip;

    fn history(root: &Path) -> History {
        History::of(&Project::in_folder(root))
    }

    #[test]
    fn a_file_unchanged_since_a_snapshot_is_stored_once() {
        let (_dir, root) = project();
        fs::write(root.join("a.tex"), "one").unwrap();
        let history = history(&root);
        history.take(&root, 0, Taken::Before("x")).unwrap();
        let stored = names_in(&history.objects()).len();
        fs::write(root.join("a.tex"), "two").unwrap();
        history.take(&root, 1, Taken::Before("x")).unwrap();
        assert_eq!(names_in(&history.objects()).len(), stored + 1);
    }

    #[test]
    fn an_automatic_snapshot_waits_ten_minutes_after_the_last_and_for_a_change() {
        let (_dir, root) = project();
        let history = history(&root);
        history.take(&root, 0, Taken::Auto).unwrap();
        fs::write(root.join("main.tex"), "changed").unwrap();
        for at in [10 * MINUTE, 10 * MINUTE + 1, 30 * MINUTE] {
            history.take(&root, at, Taken::Auto).unwrap();
        }
        assert_eq!(history.ids().unwrap(), [10 * MINUTE + 1, 0]);
        // One dated a day ahead, as by a clock once wrong, keeps no later one from being taken.
        fs::write(root.join("main.tex"), "changed again").unwrap();
        history.take(&root, DAY, Taken::Before("x")).unwrap();
        fs::write(root.join("main.tex"), "and again").unwrap();
        assert!(history.take(&root, HOUR, Taken::Auto).unwrap().is_some());
    }

    #[test]
    fn pruning_keeps_named_ones_and_a_days_then_one_an_hour_for_a_week_and_one_a_day_for_90_days() {
        let (_dir, root) = project();
        let history = history(&root);
        let (now, before) = (200 * DAY, || Taken::Before("x"));
        fs::write(root.join("old.tex"), "only in the oldest").unwrap();
        history.take(&root, now - 91 * DAY, before()).unwrap();
        fs::remove_file(root.join("old.tex")).unwrap();
        let named = now - 90 * DAY - HOUR;
        history
            .take(&root, named, Taken::Named("Sent".into()))
            .unwrap();
        let (day, hour) = (now - 50 * DAY, now - 3 * DAY);
        let times = [
            day + HOUR,
            day + 2 * HOUR,
            hour + 10 * MINUTE,
            hour + 40 * MINUTE,
            hour + 70 * MINUTE,
            now - 2 * HOUR,
            now - HOUR,
            now,
        ];
        for at in times {
            history.take(&root, at, before()).unwrap();
        }
        let kept = [
            now,
            now - HOUR,
            now - 2 * HOUR,
            hour + 70 * MINUTE,
            hour + 40 * MINUTE,
            day + 2 * HOUR,
            named,
        ];
        assert_eq!(history.ids().unwrap(), kept);
        let files = history.read(now).unwrap().files.len();
        assert_eq!(names_in(&history.objects()).len(), files);
    }

    /// It fails no change that takes a snapshot, nor leaves the others' files unkept.
    #[test]
    fn a_record_that_cant_be_read_is_passed_over_and_the_stored_files_stay() {
        let (_dir, root) = project();
        let history = history(&root);
        history.take(&root, 0, Taken::Before("x")).unwrap();
        fs::write(history.record(0), "not JSON").unwrap();
        let stored = names_in(&history.objects()).len();
        fs::write(root.join("main.tex"), "changed").unwrap();
        history.take(&root, 100 * DAY, Taken::Before("x")).unwrap();
        assert_eq!(history.list().unwrap().len(), 1);
        assert_eq!(names_in(&history.objects()).len(), stored + 1);
    }

    #[test]
    fn a_record_pruning_cant_remove_keeps_its_files() {
        let (_dir, root) = project();
        let history = history(&root);
        history.take(&root, 0, Taken::Before("x")).unwrap();
        let stored = names_in(&history.objects()).len();
        let snapshots = history.dir.join("snapshots");
        let mode =
            |mode| fs::set_permissions(&snapshots, fs::Permissions::from_mode(mode)).unwrap();
        mode(0o555);
        history.prune(100 * DAY);
        mode(0o755);
        assert_eq!(history.list().unwrap().len(), 1);
        assert_eq!(names_in(&history.objects()).len(), stored);
    }

    /// The Before Restore snapshot can't keep it, so a restore would lose it for good.
    #[test]
    fn a_restore_leaves_alone_a_file_too_large_to_keep() {
        let (_dir, root) = project();
        fs::write(root.join("data.csv"), "small").unwrap();
        let history = history(&root);
        history.take(&root, 0, Taken::Before("x")).unwrap();
        let large = fs::File::create(root.join("data.csv")).unwrap();
        large.set_len(MAX_KEPT + 1).unwrap();
        let files = history.files("0", |_| true).unwrap();
        assert!(files.iter().any(|(path, _)| path == "data.csv"));
        put_back(&root, files).unwrap();
        let len = fs::metadata(root.join("data.csv")).unwrap().len();
        assert_eq!(len, MAX_KEPT + 1);
    }

    /// A snapshot holds what the tree lists, and the tree, search and an export (and so an
    /// import, which takes back what an export leaves in) leave the history out.
    #[test]
    fn the_history_holds_the_files_the_tree_lists_and_no_walk_of_the_project_reads_it() {
        let (dir, service) = with_project();
        let project = service.project("P").unwrap();
        let root = &project.root;
        for path in ["secret.tex", "build/main.log", ".git/HEAD", ".latexmkrc"] {
            fs::create_dir_all(root.join(path).parent().unwrap()).unwrap();
            fs::write(root.join(path), "x").unwrap();
        }
        let history = History::of(&project);
        history.take(root, 0, Taken::Before("x")).unwrap();
        let files = history.read(0).unwrap().files;
        assert_eq!(files.keys().collect::<Vec<_>>(), ["main.tex", "secret.tex"]);
        assert_eq!(project.history, root.join(HISTORY_DIR));

        fs::remove_file(root.join("secret.tex")).unwrap();
        let tree = file_tree(&project).unwrap();
        assert!(tree.iter().all(|node| node.name != HISTORY_DIR));
        let secret = |_: &str, text: &str| Query::new("secret", false, false).places(text);
        let found = search_project(root, &HashMap::new(), &is_text, &secret, 100);
        assert!(found.unwrap().is_empty());
        let zip = dir.path().join("P.zip");
        export_zip(root, &zip, &[]).unwrap();
        assert!(zip_names(&zip).iter().all(|name| !name.contains("history")));
    }
}
