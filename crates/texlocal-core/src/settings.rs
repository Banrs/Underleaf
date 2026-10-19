//! Per-project settings in `<project>/.texlocal.json`, and the app's own
//! beside the projects. Settings arrive from the UI, and two of them are
//! dangerous taken as given: `mainFile` becomes an argv element for latexmk,
//! and `shellEscape` turns on arbitrary shell execution during a compile.
//! Only known keys are accepted, each validated rather than merged as sent.

use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize, Serializer};
use serde_json::{Map, Value, json};

use crate::atomic;
use crate::error::CoreError;
use crate::paths::safe_rel_file;
use crate::{BUILD_DIR, SETTINGS_FILE};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub main_file: String,
    pub engine: Engine,
    pub shell_escape: bool,
    /// Halt at the first LaTeX error instead of compiling past it.
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
    /// "<root>/build/paper.<ext>". A main file the path rules refuse has none.
    pub fn output(&self, root: &Path, ext: &str) -> Result<PathBuf, CoreError> {
        let main = safe_rel_file(root, &self.main_file)?;
        let base = Path::new(&main).file_stem().unwrap_or_default();
        let name = format!("{}.{ext}", base.to_string_lossy());
        Ok(root.join(BUILD_DIR).join(name))
    }
}

/// The TeX engine latexmk runs, by its name in the settings file.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Engine {
    #[default]
    Pdflatex,
    Xelatex,
    Lualatex,
}

impl Engine {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pdflatex => "pdflatex",
            Self::Xelatex => "xelatex",
            Self::Lualatex => "lualatex",
        }
    }

    fn named(name: &str) -> Option<Self> {
        [Self::Pdflatex, Self::Xelatex, Self::Lualatex]
            .into_iter()
            .find(|engine| engine.as_str() == name)
    }

    /// latexmk's option for it.
    pub(crate) fn flag(self) -> &'static str {
        match self {
            Self::Pdflatex => "-pdf",
            Self::Xelatex => "-xelatex",
            Self::Lualatex => "-lualatex",
        }
    }
}

impl Serialize for Engine {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

/// A JSON object from a file: empty if there is no file, an error (409) if
/// there is one that can't be read or isn't an object. Writers go through this,
/// so a file the user is mid-way through editing is never replaced by defaults.
fn load_object(path: &Path) -> Result<Map<String, Value>, CoreError> {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let unreadable = |why: String| {
        CoreError::conflict(format!(
            "“{name}” can't be read ({why}), so it was left as it is. Correct it, or delete it to start again."
        ))
    };
    let bytes = match fs::read(path) {
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(Map::new()),
        read => read.map_err(|err| unreadable(CoreError::from(err).message))?,
    };
    serde_json::from_slice(&bytes).map_err(|err| unreadable(err.to_string()))
}

/// A JSON object from a file; empty if there is none or it can't be read.
fn read_object(path: &Path) -> Map<String, Value> {
    load_object(path).unwrap_or_default()
}

/// Write `keys` over the file at `path`, itself laid over `merged` so that the
/// file's own keys, unknown ones too, stay, atomically; and answer the result.
/// A file that exists but can't be read is not written over (409).
fn update(
    path: &Path,
    mut merged: Map<String, Value>,
    keys: impl IntoIterator<Item = (String, Value)>,
) -> Result<Map<String, Value>, CoreError> {
    merged.extend(load_object(path)?);
    merged.extend(keys);
    let bytes =
        serde_json::to_vec_pretty(&merged).map_err(|e| CoreError::internal(e.to_string()))?;
    atomic::write(path, &bytes)?;
    Ok(merged)
}

/// `update` of a project's settings file, over the defaults.
fn update_project(
    root: &Path,
    keys: impl IntoIterator<Item = (String, Value)>,
) -> Result<Map<String, Value>, CoreError> {
    let Value::Object(defaults) = json!(Settings::default()) else {
        unreachable!("Settings serializes as an object");
    };
    update(&root.join(SETTINGS_FILE), defaults, keys)
}

/// Lenient read: defaults fill in anything missing or mistyped, an engine
/// this module doesn't know included, because the file on disk is
/// user-editable. The main file is checked where it is used.
pub fn read_settings(root: &Path) -> Settings {
    lenient(&read_object(&root.join(SETTINGS_FILE)))
}

fn lenient(raw: &Map<String, Value>) -> Settings {
    let text = |key: &str| raw.get(key).and_then(Value::as_str);
    let flag = |key: &str| raw.get(key).and_then(Value::as_bool);
    Settings {
        main_file: text("mainFile").map_or(Settings::default().main_file, str::to_string),
        engine: text("engine").and_then(Engine::named).unwrap_or_default(),
        shell_escape: flag("shellEscape").unwrap_or_default(),
        stop_on_first_error: flag("stopOnFirstError").unwrap_or_default(),
    }
}

/// A change to a project's settings: the keys sent are validated and applied,
/// the rest left as they are. Unknown keys are ignored.
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsPatch {
    main_file: Option<String>,
    engine: Option<String>,
    shell_escape: Option<bool>,
    stop_on_first_error: Option<bool>,
}

impl SettingsPatch {
    /// The keys sent, to store: the types have checked the flags, and this
    /// checks the engine and the main file, stored as `safe_rel_file` spells it.
    fn checked(mut self, root: &Path) -> Result<Map<String, Value>, CoreError> {
        if let Some(engine) = &self.engine
            && Engine::named(engine).is_none()
        {
            return Err(CoreError::bad_request(format!("Unknown engine: {engine}")));
        }
        if let Some(main_file) = &self.main_file {
            self.main_file = Some(safe_rel_file(root, main_file)?);
        }
        let Value::Object(mut keys) = json!(self) else {
            unreachable!("a patch serializes as an object");
        };
        keys.retain(|_, value| !value.is_null());
        Ok(keys)
    }
}

/// Apply `patch`, a `SettingsPatch` as JSON, to the project's settings and
/// return them as written.
pub fn write_settings(root: &Path, patch: &Value) -> Result<Settings, CoreError> {
    let patch = SettingsPatch::deserialize(patch)
        .map_err(|err| CoreError::bad_request(format!("Invalid settings: {err}")))?;
    // What was just written, without reading it back.
    Ok(lenient(&update_project(root, patch.checked(root)?)?))
}

/// The folders chosen for TeX's programs and for TeXpresso, which every
/// project shares; None finds the program by itself. They are kept beside
/// the projects, in a file whose dot keeps it out of the project list, and
/// read per use, so a choice made in another host applies.
#[derive(Debug, Default)]
pub(crate) struct AppSettings {
    pub tex_dir: Option<PathBuf>,
    pub texpresso_dir: Option<PathBuf>,
}

const APP_SETTINGS_FILE: &str = ".texlocal-app.json";

impl AppSettings {
    /// Read leniently, as a project's settings are: a folder missing,
    /// mistyped or empty is None.
    pub(crate) fn read(data_dir: &Path) -> Self {
        let keys = read_object(&data_dir.join(APP_SETTINGS_FILE));
        let folder = |key| {
            let dir = keys.get(key)?.as_str()?;
            (!dir.is_empty()).then(|| PathBuf::from(dir))
        };
        Self {
            tex_dir: folder("texDir"),
            texpresso_dir: folder("texpressoDir"),
        }
    }

    /// Choose the folder `key` ("texDir" or "texpressoDir"), leaving the
    /// file's other keys as they are.
    pub(crate) fn choose(data_dir: &Path, key: &str, dir: Option<&Path>) -> Result<(), CoreError> {
        // Held to read, change and write the file, so two choices keep both.
        static WRITING: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _writing = crate::lock(&WRITING);
        let chosen = (key.to_owned(), json!(dir.map(Path::to_string_lossy)));
        update(&data_dir.join(APP_SETTINGS_FILE), Map::new(), [chosen]).map(drop)
    }
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
    }
    update_project(root, [("ui".to_owned(), json!(state))])?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::project;
    use crate::projects::{create_free, list_projects};

    #[test]
    fn a_settings_patch_changes_only_its_keys_and_returns_what_a_later_read_sees() {
        let (_dir, root) = project();
        let file = root.join(SETTINGS_FILE);
        let saved =
            r#"{ "mainFile": 7, "engine": "xelatex", "stopOnFirstError": 3, "custom": "kept" }"#;
        fs::write(&file, saved).unwrap();
        let written = write_settings(&root, &json!({ "shellEscape": true, "unknown": 1 })).unwrap();
        // The file's engine stays, its mistyped main file and flag read as the
        // defaults, and its unknown key survives.
        let expected = json!({
            "mainFile": "main.tex", "engine": "xelatex", "shellEscape": true, "stopOnFirstError": false
        });
        assert_eq!(json!(written), expected);
        assert_eq!(json!(read_settings(&root)), expected);
        let raw: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
        assert_eq!(raw["custom"], "kept");

        // A patch that fails writes nothing, its valid keys included.
        let before = fs::read(&file).unwrap();
        for (bad, why) in [
            (
                json!({ "engine": "word", "shellEscape": false }),
                "Unknown engine",
            ),
            (json!({ "shellEscape": "false" }), "expected a boolean"),
            (
                json!({ "mainFile": "-interaction.tex" }),
                "Path segments cannot start",
            ),
            (
                json!({ "mainFile": "../outside.tex" }),
                "Path escapes project",
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
        // A hand edit left half-done, then something that is no object.
        for broken in ["{ \"mainFile\": \"thesis.tex\", }", "[1]"] {
            fs::write(&file, broken).unwrap();
            fs::write(&app_file, broken).unwrap();
            let ui = UiPatch {
                expanded_folders: Some(vec!["a".into()]),
                ..UiPatch::default()
            };
            assert_eq!(write_ui(root, ui).unwrap_err().status, 409);
            let err = write_settings(root, &json!({ "engine": "lualatex" })).unwrap_err();
            assert_eq!(err.status, 409);
            assert!(err.message.contains(SETTINGS_FILE), "{}", err.message);
            move_ui(root, |_| Some("moved".into()));
            let chosen = AppSettings::choose(root, "texDir", Some(Path::new("/tex")));
            assert_eq!(chosen.unwrap_err().status, 409);
            assert_eq!(fs::read_to_string(&file).unwrap(), broken);
            assert_eq!(fs::read_to_string(&app_file).unwrap(), broken);
            // Reading stays lenient: the project still opens, on defaults.
            assert_eq!(read_settings(root).main_file, "main.tex");
            assert_eq!(AppSettings::read(root).tex_dir, None);
        }
        // Nothing there is no reason to refuse: the first write makes it.
        fs::remove_file(&file).unwrap();
        write_settings(root, &json!({ "engine": "lualatex" })).unwrap();
        assert_eq!(read_settings(root).engine, Engine::Lualatex);
        // A folder where the file belongs can't be read as one.
        fs::remove_file(&file).unwrap();
        fs::create_dir(&file).unwrap();
        assert_eq!(write_ui(root, UiPatch::default()).unwrap_err().status, 409);
    }
}
