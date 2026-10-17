//! Per-project settings in `<project>/.texlocal.json`. Settings arrive from
//! the UI, and two of them are dangerous taken as given: `mainFile` becomes an
//! argv element for latexmk, and `shellEscape` turns on arbitrary shell
//! execution during a compile.
//! Only known keys are accepted, each validated rather than merged as sent.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::compile::engine_flags;
use crate::error::CoreError;
use crate::paths::safe_rel_file;
use crate::{BUILD_DIR, SETTINGS_FILE, atomic};

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
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn object(value: impl Serialize) -> Map<String, Value> {
    match serde_json::to_value(value) {
        Ok(Value::Object(map)) => map,
        _ => unreachable!("only structs and maps are given"),
    }
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
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsPatch {
    #[serde(skip_serializing_if = "Option::is_none")]
    main_file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    engine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    shell_escape: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    stop_on_first_error: Option<bool>,
}

/// Run `change` on the settings file's keys (the defaults under what the file
/// has, so its unknown keys stay) and write the result atomically.
fn update(
    root: &Path,
    change: impl FnOnce(&mut Map<String, Value>),
) -> Result<Map<String, Value>, CoreError> {
    let mut merged = object(Settings::default());
    merged.extend(read_object(&root.join(SETTINGS_FILE)));
    change(&mut merged);
    atomic::write(
        &root.join(SETTINGS_FILE),
        &serde_json::to_vec_pretty(&merged).expect("a JSON object serializes"),
    )?;
    Ok(merged)
}

/// Apply `patch`, a `SettingsPatch` as JSON, to the project's settings and
/// return them as written.
pub fn write_settings(root: &Path, patch: &Value) -> Result<Settings, CoreError> {
    if !patch.is_object() {
        return Err(CoreError::bad_request("Invalid settings"));
    }
    let mut patch = SettingsPatch::deserialize(patch)
        .map_err(|err| CoreError::bad_request(format!("Invalid settings: {err}")))?;
    if let Some(engine) = &patch.engine
        && engine_flags(engine).is_none()
    {
        return Err(CoreError::bad_request(format!("Unknown engine: {engine}")));
    }
    if let Some(main_file) = &mut patch.main_file {
        *main_file = safe_rel_file(root, main_file)?;
    }
    // What was just written, without reading it back.
    update(root, |merged| {
        merged.extend(object(&patch));
    })
    .map(|merged| lenient(&merged))
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
    update(root, |merged| {
        merged.insert("ui".into(), serde_json::json!(&state));
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
    let before = read_ui(root);
    let mut state = before.clone();
    for folder in &mut state.expanded_folders {
        if let Some(new) = moved(folder) {
            *folder = new;
        }
    }
    for key in &mut state.folded_headings {
        if let Some((file, rest)) = key.split_once('\t')
            && let Some(new) = moved(file)
        {
            *key = format!("{new}\t{rest}");
        }
    }
    if state != before {
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

    #[test]
    fn a_renamed_entry_takes_its_saved_interface_state_along() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let list = |names: &[&str]| names.iter().map(ToString::to_string).collect::<Vec<_>>();
        let patch = UiPatch {
            expanded_folders: Some(list(&["ch", "other"])),
            folded_headings: Some(list(&["ch/a.tex\t1:T#1", "b.tex\t1:T#1"])),
        };
        write_ui(root, patch).unwrap();
        move_ui(root, |path| {
            (path == "ch" || path == "ch/a.tex").then(|| path.replace("ch", "part"))
        });
        let state = read_ui(root);
        assert_eq!(state.expanded_folders, list(&["other", "part"]));
        assert_eq!(
            state.folded_headings,
            list(&["b.tex\t1:T#1", "part/a.tex\t1:T#1"])
        );
    }
}
