//! Per-project settings in `<project>/.texlocal.json`. Settings arrive from
//! the UI, and two of them are dangerous taken as given: `mainFile` becomes an
//! argv element for latexmk, and `shellEscape` turns on arbitrary shell
//! execution during a compile.
//! Only known keys are accepted, each validated rather than merged as sent.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::atomic;
use crate::compile::engine_flags;
use crate::error::CoreError;
use crate::paths::safe_rel_file;
use crate::{BUILD_DIR, SETTINGS_FILE};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub main_file: String,
    pub engine: String,
    pub shell_escape: bool,
    /// Halt at the first LaTeX error instead of compiling past it.
    pub stop_on_first_error: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            main_file: "main.tex".into(),
            engine: "pdflatex".into(),
            shell_escape: false,
            stop_on_first_error: false,
        }
    }
}

/// A JSON object from a file; empty if the file is missing or not one.
pub(crate) fn read_object(path: &Path) -> Map<String, Value> {
    fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Map<String, Value>>(&bytes).ok())
        .unwrap_or_default()
}

/// Lenient read: defaults fill in anything missing or mistyped. Validation of
/// the values happens where they are used (compile re-checks both mainFile and
/// engine), because the file on disk is user-editable.
pub fn read_settings(root: &Path) -> Settings {
    lenient(&read_object(&root.join(SETTINGS_FILE)))
}

fn lenient(raw: &Map<String, Value>) -> Settings {
    let text = |key: &str| raw.get(key).and_then(Value::as_str).map(str::to_string);
    let flag = |key: &str| raw.get(key).and_then(Value::as_bool);
    let defaults = Settings::default();
    Settings {
        main_file: text("mainFile").unwrap_or(defaults.main_file),
        engine: text("engine").unwrap_or(defaults.engine),
        shell_escape: flag("shellEscape").unwrap_or(defaults.shell_escape),
        stop_on_first_error: flag("stopOnFirstError").unwrap_or(defaults.stop_on_first_error),
    }
}

/// A change to a project's settings: the keys sent are validated and applied,
/// the rest left as they are. Unknown keys are ignored.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsPatch {
    pub main_file: Option<String>,
    pub engine: Option<String>,
    pub shell_escape: Option<bool>,
    pub stop_on_first_error: Option<bool>,
}

impl SettingsPatch {
    fn apply(&self, root: &Path, merged: &mut Map<String, Value>) -> Result<(), CoreError> {
        if let Some(engine) = &self.engine {
            if engine_flags(engine).is_none() {
                return Err(CoreError::bad_request(format!("Unknown engine: {engine}")));
            }
            merged.insert("engine".into(), engine.as_str().into());
        }
        for (key, flag) in [
            ("shellEscape", self.shell_escape),
            ("stopOnFirstError", self.stop_on_first_error),
        ] {
            if let Some(on) = flag {
                merged.insert(key.into(), on.into());
            }
        }
        if let Some(main_file) = &self.main_file {
            merged.insert("mainFile".into(), safe_rel_file(root, main_file)?.into());
        }
        Ok(())
    }
}

/// Run `change` on the settings file's keys (the defaults under what the file
/// has, so its unknown keys stay) and write the result atomically.
fn update(
    root: &Path,
    change: impl FnOnce(&mut Map<String, Value>) -> Result<(), CoreError>,
) -> Result<Map<String, Value>, CoreError> {
    let Value::Object(mut merged) = serde_json::to_value(Settings::default()).unwrap() else {
        unreachable!("Settings serializes as an object");
    };
    merged.extend(read_object(&root.join(SETTINGS_FILE)));
    change(&mut merged)?;
    let bytes =
        serde_json::to_vec_pretty(&merged).map_err(|e| CoreError::internal(e.to_string()))?;
    atomic::write(&root.join(SETTINGS_FILE), &bytes)?;
    Ok(merged)
}

/// Apply `patch` to the project's settings and return them as written.
pub fn apply_patch(root: &Path, patch: &SettingsPatch) -> Result<Settings, CoreError> {
    // What was just written, without reading it back.
    update(root, |merged| patch.apply(root, merged)).map(|merged| lenient(&merged))
}

/// `apply_patch` for a patch as JSON.
pub fn write_settings(root: &Path, patch: &Value) -> Result<Settings, CoreError> {
    if !patch.is_object() {
        return Err(CoreError::bad_request("Invalid settings"));
    }
    let patch = SettingsPatch::deserialize(patch)
        .map_err(|err| CoreError::bad_request(format!("Invalid settings: {err}")))?;
    apply_patch(root, &patch)
}

/// What a host keeps of a project's interface, with the project: it moves
/// with a rename of the project or of a file in it. Held in the settings file
/// under `ui`, which only this module writes.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UiState {
    /// Folders open in the file tree, by project path.
    pub expanded_folders: Vec<String>,
    /// Outline headings folded, by `OutlineNode::fold_key`.
    pub folded_headings: Vec<String>,
}

/// Each list sent replaces the saved one.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UiPatch {
    pub expanded_folders: Option<Vec<String>>,
    pub folded_headings: Option<Vec<String>>,
}

/// More than any project has, so a runaway host can't fill the settings file.
const UI_LIMIT: usize = 10_000;

pub fn read_ui(root: &Path) -> UiState {
    read_object(&root.join(SETTINGS_FILE))
        .remove("ui")
        .and_then(|ui| serde_json::from_value(ui).ok())
        .unwrap_or_default()
}

fn store_ui(root: &Path, mut state: UiState) -> Result<UiState, CoreError> {
    for list in [&mut state.expanded_folders, &mut state.folded_headings] {
        list.sort();
        list.dedup();
        if list.len() > UI_LIMIT {
            return Err(CoreError::bad_request("Too much interface state"));
        }
    }
    let ui = serde_json::to_value(&state).map_err(|e| CoreError::internal(e.to_string()))?;
    update(root, |merged| {
        merged.insert("ui".into(), ui);
        Ok(())
    })?;
    Ok(state)
}

pub fn write_ui(root: &Path, patch: UiPatch) -> Result<UiState, CoreError> {
    let mut state = read_ui(root);
    state.expanded_folders = patch.expanded_folders.unwrap_or(state.expanded_folders);
    state.folded_headings = patch.folded_headings.unwrap_or(state.folded_headings);
    store_ui(root, state)
}

/// Move the saved state of a renamed entry with it, as `moved` gives each
/// project path's new one (None: unmoved): folders by their path, folds by the
/// file their key starts with. Best effort: the state is a convenience.
pub(crate) fn move_ui(root: &Path, moved: impl Fn(&str) -> Option<String>) {
    let mut state = read_ui(root);
    let mut changed = false;
    for folder in &mut state.expanded_folders {
        if let Some(new) = moved(folder) {
            (*folder, changed) = (new, true);
        }
    }
    for key in &mut state.folded_headings {
        let new = key
            .split_once('\t')
            .and_then(|(file, rest)| Some(format!("{}\t{rest}", moved(file)?)));
        if let Some(new) = new {
            (*key, changed) = (new, true);
        }
    }
    if changed {
        let _ = store_ui(root, state);
    }
}

/// The compiled PDF path for a project, with its settings as on disk.
pub fn compiled_pdf_path(root: &Path) -> Result<PathBuf, CoreError> {
    read_settings(root).pdf_path(root)
}

impl Settings {
    /// The compiled PDF path — the ONE place this is derived.
    /// mainFile "paper.tex" → "<root>/build/paper.pdf".
    pub fn pdf_path(&self, root: &Path) -> Result<PathBuf, CoreError> {
        let base = main_base_name(&safe_rel_file(root, &self.main_file)?);
        Ok(root.join(BUILD_DIR).join(format!("{base}.pdf")))
    }
}

/// The main file's name without its extension ("chapters/paper.tex" → "paper").
pub fn main_base_name(rel_slash: &str) -> String {
    Path::new(rel_slash).file_stem().map_or_else(
        || rel_slash.to_string(),
        |s| s.to_string_lossy().into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_patch_changes_only_the_keys_it_names_and_keeps_the_files_other_keys() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::write(
            root.join(SETTINGS_FILE),
            r#"{"custom": 7, "engine": "xelatex"}"#,
        )
        .unwrap();
        let patch = json!({ "shellEscape": true, "unknown": 1 });
        let written = write_settings(root, &patch).unwrap();
        assert_eq!(
            (written.engine.as_str(), written.shell_escape),
            ("xelatex", true)
        );
        assert_eq!(read_settings(root).main_file, "main.tex");
        assert_eq!(read_object(&root.join(SETTINGS_FILE))["custom"], 7);
        // Nothing is written for a patch that fails.
        let before = fs::read(root.join(SETTINGS_FILE)).unwrap();
        for bad in [
            json!({ "engine": "word", "shellEscape": false }),
            json!({ "stopOnFirstError": "yes" }),
            json!({ "mainFile": "../x.tex" }),
            json!([1]),
        ] {
            assert_eq!(write_settings(root, &bad).unwrap_err().status, 400, "{bad}");
        }
        assert_eq!(fs::read(root.join(SETTINGS_FILE)).unwrap(), before);
    }

    #[test]
    fn interface_state_replaces_each_list_it_names_and_survives_settings_changes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let list = |names: &[&str]| names.iter().map(ToString::to_string).collect::<Vec<_>>();
        let patch = |value: serde_json::Value| serde_json::from_value::<UiPatch>(value).unwrap();
        assert_eq!(read_ui(root), UiState::default());
        write_ui(root, patch(json!({ "expandedFolders": ["b", "a", "b"] }))).unwrap();
        write_ui(root, patch(json!({ "foldedHeadings": ["x\t1:T#1"] }))).unwrap();
        write_settings(root, &json!({ "engine": "lualatex" })).unwrap();
        let state = read_ui(root);
        assert_eq!(state.expanded_folders, list(&["a", "b"]));
        assert_eq!(state.folded_headings, list(&["x\t1:T#1"]));
        write_ui(root, patch(json!({ "expandedFolders": [] }))).unwrap();
        assert_eq!(read_ui(root).folded_headings, list(&["x\t1:T#1"]));
        assert_eq!(read_settings(root).engine, "lualatex");
        let flood = (0..=UI_LIMIT).map(|n| n.to_string()).collect();
        let flood = UiPatch {
            expanded_folders: Some(flood),
            ..UiPatch::default()
        };
        assert_eq!(write_ui(root, flood).unwrap_err().status, 400);
    }
}
