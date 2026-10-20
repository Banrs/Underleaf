//! Per-project settings in `<project>/.texlocal.json`, and the app's own
//! beside the projects.

use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::atomic;
use crate::error::CoreError;
use crate::paths::safe_rel_file;
use crate::{BUILD_DIR, SETTINGS_FILE};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub main_file: String,
    pub engine: Engine,
    pub shell_escape: bool,
    pub stop_on_first_error: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            main_file: "main.tex".into(),
            engine: Engine::default(),
            shell_escape: false,
            stop_on_first_error: false,
        }
    }
}

impl Settings {
    /// Where a build writes its output with extension `ext`, named as latexmk
    /// names it after the main file: mainFile "chapters/paper.tex" gives
    /// "<root>/build/paper.<ext>".
    pub fn output(&self, root: &Path, ext: &str) -> Result<PathBuf, CoreError> {
        let main = safe_rel_file(&self.main_file)?;
        let base = Path::new(&main).file_stem().unwrap_or_default();
        let name = format!("{}.{ext}", base.to_string_lossy());
        Ok(root.join(BUILD_DIR).join(name))
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Engine {
    #[default]
    Pdflatex,
    Xelatex,
    Lualatex,
}

impl Engine {
    /// latexmk's option for it.
    pub(crate) fn flag(self) -> &'static str {
        match self {
            Self::Pdflatex => "-pdf",
            Self::Xelatex => "-xelatex",
            Self::Lualatex => "-lualatex",
        }
    }
}

/// The settings file: the settings, and under `ui` what a host keeps of the
/// project's interface, which moves with a rename of the project or a file.
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct ProjectFile {
    #[serde(flatten)]
    settings: Settings,
    ui: UiState,
}

/// A JSON file as `T`: the default if there is no file, an error (409) if it
/// can't be read, so a file the user is mid-way through editing is never
/// replaced by defaults.
fn load<T: DeserializeOwned + Default>(path: &Path) -> Result<T, CoreError> {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let unreadable = |why: String| {
        CoreError::conflict(format!(
            "“{name}” can't be read ({why}), so it was left as it is. Correct it, or delete it to start again."
        ))
    };
    let bytes = match fs::read(path) {
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(T::default()),
        read => read.map_err(|err| unreadable(CoreError::from(err).message))?,
    };
    serde_json::from_slice(&bytes).map_err(|err| unreadable(err.to_string()))
}

fn store(path: &Path, value: &impl Serialize) -> Result<(), CoreError> {
    let bytes = serde_json::to_vec_pretty(value).map_err(|e| CoreError::internal(e.to_string()))?;
    atomic::write(path, &bytes)?;
    Ok(())
}

fn update_project(
    root: &Path,
    change: impl FnOnce(&mut ProjectFile) -> Result<(), CoreError>,
) -> Result<ProjectFile, CoreError> {
    let path = root.join(SETTINGS_FILE);
    let mut file: ProjectFile = load(&path)?;
    change(&mut file)?;
    store(&path, &file)?;
    Ok(file)
}

/// The defaults where the file is missing or can't be read.
pub fn read_settings(root: &Path) -> Settings {
    load::<ProjectFile>(&root.join(SETTINGS_FILE))
        .unwrap_or_default()
        .settings
}

/// Merge `patch`'s keys over the project's settings and return them as written.
pub fn write_settings(root: &Path, patch: &Value) -> Result<Settings, CoreError> {
    let file = update_project(root, |file| {
        let Value::Object(patch) = patch else {
            return Err(CoreError::bad_request("Invalid settings"));
        };
        let Ok(Value::Object(mut merged)) = serde_json::to_value(&file.settings) else {
            unreachable!("settings serialize as an object");
        };
        merged.extend(patch.clone());
        let mut settings = Settings::deserialize(Value::Object(merged))
            .map_err(|err| CoreError::bad_request(format!("Invalid settings: {err}")))?;
        // latexmk would read a main file starting with "-" as an option.
        settings.main_file = safe_rel_file(&settings.main_file)?;
        file.settings = settings;
        Ok(())
    })?;
    Ok(file.settings)
}

/// The folders chosen for TeX's programs and for TeXpresso, which every
/// project shares; None finds the program by itself. Kept beside the
/// projects, in a file whose dot keeps it out of the project list.
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct AppSettings {
    pub tex_dir: Option<PathBuf>,
    pub texpresso_dir: Option<PathBuf>,
}

const APP_SETTINGS_FILE: &str = ".texlocal-app.json";

impl AppSettings {
    pub(crate) fn read(data_dir: &Path) -> Self {
        load(&data_dir.join(APP_SETTINGS_FILE)).unwrap_or_default()
    }

    pub(crate) fn update(data_dir: &Path, change: impl FnOnce(&mut Self)) -> Result<(), CoreError> {
        let path = data_dir.join(APP_SETTINGS_FILE);
        let mut app: Self = load(&path)?;
        change(&mut app);
        store(&path, &app)
    }
}

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

pub fn read_ui(root: &Path) -> UiState {
    load::<ProjectFile>(&root.join(SETTINGS_FILE))
        .unwrap_or_default()
        .ui
}

fn store_ui(root: &Path, change: impl FnOnce(&mut UiState)) -> Result<UiState, CoreError> {
    let file = update_project(root, |file| {
        change(&mut file.ui);
        for list in [&mut file.ui.expanded_folders, &mut file.ui.folded_headings] {
            list.sort();
            list.dedup();
        }
        Ok(())
    })?;
    Ok(file.ui)
}

pub fn write_ui(root: &Path, patch: UiPatch) -> Result<UiState, CoreError> {
    store_ui(root, |state| {
        if let Some(folders) = patch.expanded_folders {
            state.expanded_folders = folders;
        }
        if let Some(headings) = patch.folded_headings {
            state.folded_headings = headings;
        }
    })
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
        let _ = store_ui(root, |saved| *saved = state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::project;
    use crate::projects::{create_free, list_projects};
    use serde_json::json;

    #[test]
    fn a_settings_patch_changes_only_its_keys_and_returns_what_a_later_read_sees() {
        let (_dir, root) = project();
        let file = root.join(SETTINGS_FILE);
        fs::write(&file, r#"{ "engine": "xelatex" }"#).unwrap();
        let written = write_settings(&root, &json!({ "shellEscape": true, "unknown": 1 })).unwrap();
        let expected = json!({
            "mainFile": "main.tex", "engine": "xelatex", "shellEscape": true, "stopOnFirstError": false
        });
        assert_eq!(json!(written), expected);
        assert_eq!(json!(read_settings(&root)), expected);

        // A patch that fails writes nothing, its valid keys included.
        let before = fs::read(&file).unwrap();
        for (bad, why) in [
            (
                json!({ "engine": "word", "shellEscape": false }),
                "unknown variant",
            ),
            (
                json!({ "mainFile": "-interaction.tex" }),
                "Path segments cannot start",
            ),
            (json!([1]), "Invalid settings"),
        ] {
            let err = write_settings(&root, &bad).unwrap_err();
            assert_eq!(err.status, 400, "{}", err.message);
            assert!(err.message.contains(why), "{:?} lacks {why:?}", err.message);
        }
        assert_eq!(fs::read(&file).unwrap(), before);

        // A nested main file names the build's output, and the library lists it.
        create_free(&root, "chapters/paper.tex", false).unwrap();
        let settings = write_settings(&root, &json!({ "mainFile": "chapters/paper.tex" })).unwrap();
        let pdf = settings.output(&root, "pdf").unwrap();
        assert_eq!(pdf, root.join(BUILD_DIR).join("paper.pdf"));
        let listed = list_projects(root.parent().unwrap()).unwrap().remove(0);
        assert_eq!([listed.id, listed.main_file], ["P", "chapters/paper.tex"]);
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
        assert_eq!(read_settings(root).engine, Engine::Lualatex);
    }

    #[test]
    fn a_settings_file_that_cannot_be_read_is_never_written_over() {
        let dir = tempfile::tempdir().unwrap();
        let (root, file) = (dir.path(), dir.path().join(SETTINGS_FILE));
        let app_file = root.join(APP_SETTINGS_FILE);
        // A hand edit left half-done.
        let broken = "{ \"mainFile\": \"thesis.tex\", }";
        fs::write(&file, broken).unwrap();
        fs::write(&app_file, broken).unwrap();
        let err = write_settings(root, &json!({ "engine": "lualatex" })).unwrap_err();
        assert_eq!(err.status, 409);
        assert!(err.message.contains(SETTINGS_FILE), "{}", err.message);
        let chosen = AppSettings::update(root, |app| app.tex_dir = Some("/tex".into()));
        assert_eq!(chosen.unwrap_err().status, 409);
        assert_eq!(fs::read_to_string(&file).unwrap(), broken);
        assert_eq!(fs::read_to_string(&app_file).unwrap(), broken);
        // Reading gives the defaults: the project still opens.
        assert_eq!(read_settings(root).main_file, "main.tex");
        assert_eq!(AppSettings::read(root).tex_dir, None);
    }
}
