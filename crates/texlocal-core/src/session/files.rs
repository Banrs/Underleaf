use std::path::PathBuf;

use serde_json::json;
use texlocal_latex::{FileKind, file_kind};

use super::Pending;
use super::actor::{Actor, Later, Timer};
use super::documents::CloseReason;
use super::watch::{self, TreeIndex};
use crate::events::{DocumentRenamed, Event};
use crate::import::{self, ImportConflict, Imported};
use crate::paths::{self, Project, within};
use crate::projects::{self, RenameResult};
use crate::settings::{self, ProjectSettings, SettingsPatch, UiPatch};
use crate::{CoreError, zipexport};

const MAIN_FILE_TRASH: &str = "Choose a different main file before moving this to the Trash.";

impl Actor {
    pub fn deleted(&mut self, path: &str, trashed: bool) {
        self.deleting.remove(path);
        if trashed {
            for doc in self.docs_within(path) {
                self.close_doc(&doc, CloseReason::Deleted);
            }
            self.reload_tree();
        }
    }

    pub fn create_entry(
        &mut self,
        folder: &str,
        name: &str,
        dir: bool,
    ) -> Result<String, CoreError> {
        let path = paths::in_folder(folder, name);
        let made = self.service.with_project(&self.project_id, |project| {
            projects::create_free(&project.root, &path, dir)
        })?;
        self.reload_tree();
        Ok(made)
    }

    pub fn deleting(&self, path: &str) -> bool {
        self.deleting.iter().any(|entry| within(path, entry))
    }

    pub fn files_changed_on_disk(&mut self) {
        let changes = std::mem::take(&mut self.fs_pending);
        let docs: Vec<String> = self.docs.keys().cloned().collect();
        let meaning = watch::classify(&self.project.root, &changes, &self.tree, &docs);
        for path in &meaning.docs {
            self.check_disk(path);
        }
        let others: Vec<&String> = meaning
            .listed
            .iter()
            .filter(|p| !self.docs.contains_key(*p))
            .collect();
        let scan = |path: &&String| matches!(file_kind(path), FileKind::Tex | FileKind::Bib);
        if meaning.tree || others.iter().any(scan) {
            self.after(Timer::Symbols);
        }
        if !others.is_empty() {
            let paths = others.iter().map(|&path| path.clone()).collect();
            self.emit(Event::FilesChanged(paths));
        }
        if meaning.tree || !others.is_empty() {
            self.edits += 1;
            self.mark_outdated();
            if self.auto_compile {
                self.later.push_back(Later::Compile(true));
            }
        }
        if self.live.active() {
            self.live.disk_paths.extend(meaning.listed.iter().cloned());
        }
        let main = self.tree.main.clone();
        if meaning.tree {
            self.reload_tree();
        }
        if meaning.settings {
            let chosen = settings::read_settings(&self.project.settings).main_file;
            let chosen = paths::fold_case(&chosen);
            let mut files = self.tree.files.iter();
            if files.find(|f| paths::fold_case(f) == chosen) != main.as_ref() {
                self.main_file_changed();
            }
        }
        if self.live.active() && !self.live.disk_paths.is_empty() {
            self.after(Timer::Disk);
        }
    }

    pub fn reload_tree(&mut self) {
        let Ok(tree) = projects::file_tree(&self.project) else {
            return;
        };
        let index = TreeIndex::of(&tree);
        if index == self.tree {
            return;
        }
        self.tree = index;
        self.after(Timer::Symbols);
        self.emit(Event::Tree(tree));
        self.live_files_changed();
    }

    pub fn import(
        &mut self,
        dir: &str,
        paths: &[PathBuf],
        conflict: Option<ImportConflict>,
    ) -> Result<Imported, CoreError> {
        let imported = import::import_files(&self.service, &self.project_id, dir, paths, conflict)?;
        self.reload_tree();
        Ok(imported)
    }

    pub fn export(&self, dest: PathBuf, for_arxiv: bool, reply: Pending<()>) {
        let project = self.project.clone();
        tokio::task::spawn_blocking(move || {
            reply.send(zipexport::export_zip(&project, &dest, for_arxiv));
        });
    }

    pub fn write_ui(&self, patch: UiPatch) -> Result<(), CoreError> {
        let write = |project: &Project| settings::write_ui(&project.ui, patch);
        self.service.with_project(&self.project_id, write)
    }

    pub fn pdf_path(&self) -> Result<String, CoreError> {
        let settings = settings::read_settings(&self.project.settings);
        let pdf = settings.output(&self.project.build, "pdf")?;
        Ok(pdf.to_string_lossy().into_owned())
    }

    pub fn rename(&mut self, from: &str, to: &str) -> Result<Option<RenameResult>, CoreError> {
        if !self.save_edits(true)? {
            return Ok(None);
        }
        let (renamed, main) = self.service.with_project(&self.project_id, |project| {
            let main = settings::read_settings(&project.settings).main_file;
            let renamed = projects::rename_entry(project, from, to)?;
            self.preview.stop(&project.root)?;
            Ok((renamed, main))
        })?;
        self.live_follow();
        let (from, to) = (renamed.from.as_str(), renamed.to.as_str());
        for path in self.docs_within(to) {
            if !within(&path, from) {
                self.close_doc(&path, CloseReason::Gone);
            }
        }
        for old in self.docs_within(from) {
            let new = format!("{to}{}", paths::after_entry(&old, from).expect("within"));
            let mut doc = self.docs.remove(&old).expect("listed");
            doc.path.clone_from(&new);
            doc.doc.moved(&new);
            doc.shown = None;
            self.docs.insert(new.clone(), doc);
            if let Some(edit) = self.last_edits.remove(&old) {
                self.last_edits.insert(new.clone(), edit);
            }
            let moved = DocumentRenamed {
                from: old,
                to: new.clone(),
            };
            self.emit(Event::DocumentRenamed(moved));
            self.publish_doc(&new);
        }
        self.reload_tree();
        if renamed.main_file != main {
            self.main_file_changed();
        }
        Ok(Some(renamed))
    }

    pub fn set_settings(
        &mut self,
        patch: &SettingsPatch,
        build: bool,
    ) -> Result<ProjectSettings, CoreError> {
        let (updated, main_changed) = self.service.with_project(&self.project_id, |project| {
            let main = settings::read_settings(&project.settings).main_file;
            let updated = settings::write_settings(&project.settings, &json!(patch))?;
            if let Some(on) = patch.shell_escape {
                settings::grant(project, on)?;
            }
            let main_changed = updated.main_file != main;
            if main_changed {
                self.preview.stop(&project.root)?;
            }
            Ok((settings::shown(project), main_changed))
        })?;
        if main_changed {
            self.main_file_changed();
        } else if build && self.auto_compile {
            self.later.push_back(Later::Compile(true));
        }
        Ok(updated)
    }

    fn main_file_changed(&mut self) {
        self.reload_tree();
        self.live_follow();
        let building = self.builds.compiling;
        self.stop_compile();
        if self.auto_compile || building {
            self.later.push_back(Later::Compile(self.auto_compile));
        }
    }

    pub fn prepare_delete(&mut self, path: &str) -> Result<bool, CoreError> {
        if !self.flush_all(true)? || !self.dirty_paths().is_empty() {
            return Ok(false);
        }
        let main = settings::read_settings(&self.project.settings).main_file;
        if paths::after_entry(&main, path).is_some() {
            return Err(CoreError::conflict(MAIN_FILE_TRASH));
        }
        self.deleting.insert(path.to_owned());
        Ok(true)
    }
}
