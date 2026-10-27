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
pub(super) const MAX_KEPT: u64 = 20 << 20;

pub(crate) enum Taken {
    Auto,
    Before(&'static str),
    Named(String),
}

#[derive(Serialize, Deserialize)]
struct Snapshot {
    name: Option<String>,
    reason: Option<String>,
    files: BTreeMap<String, String>,
}

#[derive(Debug, Serialize)]
pub(crate) struct Entry {
    id: String,
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

    pub fn take(&self, root: &Path, now: i64, taken: Taken) -> Result<Option<i64>, CoreError> {
        let ids = self.ids()?;
        let latest = ids.iter().find_map(|&id| Some((id, self.read(id).ok()?)));
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
            let kept = snapshot.name.is_some()
                || age <= DAY
                || age <= 7 * DAY && periods.insert((HOUR, id / HOUR))
                || age > 7 * DAY && age <= 90 * DAY && periods.insert((DAY, id / DAY));
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
    use super::*;

    #[test]
    fn pruning_keeps_named_and_recent_versions_then_one_an_hour_then_one_a_day() {
        let dir = tempfile::tempdir().unwrap();
        let history = History {
            dir: dir.path().into(),
        };
        let now = 1000 * DAY;
        let versions = [
            ("recent", now - HOUR, None),
            ("hour", now - 2 * DAY - 10 * MINUTE, None),
            ("same-hour", now - 2 * DAY - 20 * MINUTE, None),
            ("day", now - 30 * DAY - HOUR, None),
            ("same-day", now - 30 * DAY - 2 * HOUR, None),
            ("old", now - 100 * DAY, None),
            ("named", now - 100 * DAY - 1, Some("Draft")),
        ];
        fs::create_dir_all(history.objects()).unwrap();
        fs::write(history.objects().join("loose"), "").unwrap();
        for (object, id, name) in versions {
            fs::write(history.objects().join(object), "").unwrap();
            let files = BTreeMap::from([("main.tex".to_owned(), object.to_owned())]);
            let snapshot = Snapshot {
                name: name.map(str::to_owned),
                reason: None,
                files,
            };
            history.write(id, &snapshot).unwrap();
        }
        history.prune(now);
        let kept = [versions[0].1, versions[1].1, versions[3].1, versions[6].1];
        assert_eq!(history.ids().unwrap(), kept);
        let objects = fs::read_dir(history.objects()).unwrap();
        let mut objects: Vec<_> = objects.map(|entry| entry.unwrap().file_name()).collect();
        objects.sort_unstable();
        assert_eq!(objects, ["day", "hour", "named", "recent"]);
    }
}
