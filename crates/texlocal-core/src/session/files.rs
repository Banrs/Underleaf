use std::path::{Path, PathBuf};

use texlocal_latex::{is_source, is_text};

use super::Pending;
use super::actor::{Actor, Later, Timer};
use crate::events::{Event, Renamed};
use crate::import::{self, ImportConflict, Imported};
use crate::messages;
use crate::paths::{self, within};
use crate::projects::{self, RenameResult};
use crate::settings::{self, SettingsPatch, UiPatch};
use crate::{CoreError, sys, zipexport};

impl Actor {
    pub fn trash(&mut self, path: &str) -> Result<Option<PathBuf>, CoreError> {
        if !self.docs.flush_all(&mut self.core, true)? {
            return Ok(None);
        }
        let main = settings::read_settings(&self.core.project.settings).main_file;
        if within(&main, path) {
            return Err(CoreError::conflict(messages::main_file_trash()));
        }
        let trashed = sys::trash(&paths::safe_path(&self.core.project.root, path)?)?;
        if matches!(&self.docs.open, Some(open) if within(open, path))
            && let Some(main) = self.tree.main.clone()
        {
            let _ = self.open_file(&main);
        }
        for doc in self.docs.within(path) {
            self.close_doc(&doc, false);
        }
        self.reload_tree();
        Ok(Some(trashed))
    }

    pub fn put_back(&mut self, path: &str, trashed: &Path) -> Result<(), CoreError> {
        projects::untrash(trashed, &paths::safe_write_path(&self.core.project, path)?)?;
        self.reload_tree();
        Ok(())
    }

    pub fn create_entry(
        &mut self,
        folder: &str,
        name: &str,
        dir: bool,
    ) -> Result<String, CoreError> {
        let path = paths::in_folder(folder, name);
        let made = projects::create_free(&self.core.project, &path, dir)?;
        self.reload_tree();
        Ok(made)
    }

    pub fn files_changed_on_disk(&mut self) {
        let docs: Vec<String> = self.docs.keys().cloned().collect();
        let meaning = self.tree.take_changes(&self.core, &docs);
        for path in &meaning.docs {
            if self.docs.check_disk(&mut self.core, path) {
                self.closed();
            }
        }
        let others: Vec<&String> = meaning
            .listed
            .iter()
            .filter(|p| !self.docs.contains_key(*p))
            .collect();
        if meaning.tree || others.iter().any(|path| is_source(path)) {
            self.core.after(Timer::Symbols);
        }
        if !others.is_empty() {
            let paths = others.iter().map(|&path| path.clone()).collect();
            self.core.emit(Event::FilesChanged(paths));
        }
        if meaning.tree || !others.is_empty() {
            self.builds.edited(&mut self.core, &self.docs, None);
            if self.core.auto_compile {
                self.core.later.push_back(Later::Compile(true));
            }
        }
        self.live.disk_changed(&mut self.core, &meaning.listed);
        let main = self.tree.main.clone();
        if meaning.tree {
            self.reload_tree();
        }
        if meaning.settings {
            self.main_file_changed(main.as_ref());
            self.tree.publish_project(&mut self.core);
        }
    }

    pub fn reload_tree(&mut self) {
        if let Ok(tree) = projects::file_tree(&self.core.project)
            && self.show_tree(tree)
        {
            self.core.after(Timer::Symbols);
            self.live.files_changed(&mut self.core, &self.tree);
        }
    }

    pub fn import(
        &mut self,
        dir: &str,
        paths: &[PathBuf],
        conflict: Option<ImportConflict>,
    ) -> Result<Imported, CoreError> {
        let imported = import::import_files(&self.core.project, dir, paths, conflict)?;
        self.reload_tree();
        Ok(imported)
    }

    pub fn export(&mut self, dest: PathBuf, for_arxiv: bool, reply: Pending<()>) {
        if let Err(err) = self.docs.save_first(&mut self.core) {
            return reply.send(Err(err));
        }
        let project = self.core.project.clone();
        tokio::task::spawn_blocking(move || {
            reply.send(zipexport::export_zip(&project, &dest, for_arxiv));
        });
    }

    pub fn write_ui(&self, patch: UiPatch) -> Result<(), CoreError> {
        settings::write_ui(&self.core.project.ui, patch)
    }

    pub fn rename(&mut self, from: &str, to: &str) -> Result<Option<RenameResult>, CoreError> {
        if !self.docs.save_edits(&mut self.core, true)? {
            return Ok(None);
        }
        let renamed = projects::rename_entry(&self.core.project, from, to)?;
        let (from, to) = (renamed.from.clone(), renamed.to.clone());
        self.core.emit(Event::Renamed(Renamed { from, to }));
        self.live.restart(&mut self.core);
        let (from, to) = (renamed.from.as_str(), renamed.to.as_str());
        for path in self.docs.within(to) {
            if !within(&path, from) {
                self.close_doc(&path, false);
            }
        }
        for (old, new) in self.docs.moved(from, to) {
            self.builds.moved(&old, &new);
        }
        if let Some(open) = self.docs.open.clone().filter(|open| is_text(open)) {
            let _ = self.open_document(&open);
        }
        self.docs.publish(&mut self.core);
        self.builds.publish(&mut self.core, &self.docs);
        self.live.publish(&mut self.core, &self.docs, false);
        self.reload_tree();
        if renamed.main_moved {
            self.builds.main_changed(&mut self.core);
        }
        Ok(Some(renamed))
    }

    pub fn set_settings(&mut self, patch: &SettingsPatch, build: bool) -> Result<(), CoreError> {
        let main = self.tree.main.clone();
        let project = &self.core.project;
        settings::write_settings(project, patch)?;
        let granted = patch.shell_escape.map(|on| settings::grant(project, on));
        if !self.main_file_changed(main.as_ref()) && build && self.core.auto_compile {
            self.core.later.push_back(Later::Compile(true));
        }
        self.tree.publish_project(&mut self.core);
        granted.unwrap_or(Ok(()))
    }

    /// Whether the settings now name a main file other than `was`, restarting what depends on it if so. A change of
    /// case alone names the same file.
    fn main_file_changed(&mut self, was: Option<&String>) -> bool {
        let chosen = settings::read_settings(&self.core.project.settings).main_file;
        let mut files = self.tree.files.iter();
        if files.find(|file| paths::same_folded(file, &chosen)) == was {
            return false;
        }
        self.live.restart(&mut self.core);
        self.reload_tree();
        self.builds.main_changed(&mut self.core);
        true
    }
}
