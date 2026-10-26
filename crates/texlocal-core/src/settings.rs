//! A project's settings and ui state, each in the file its `Project` names (`.texlocal.json`
//! in a library project), and the app's own beside the projects. Shell escape isn't a setting a
//! project's files can give: it is granted in the ui state's file, which only the app writes,
//! to the folder it was granted for.

use std::fs;
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::atomic;
use crate::error::CoreError;
use crate::paths::{Project, identity, safe_rel_file};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub main_file: String,
    pub engine: Engine,
    pub stop_on_first_error: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            main_file: "main.tex".into(),
            engine: Engine::default(),
            stop_on_first_error: false,
        }
    }
}

impl Settings {
    /// Where a build writes its output with extension `ext` in the folder `build`, named as
    /// latexmk names it after the main file.
    pub fn output(&self, build: &Path, ext: &str) -> Result<PathBuf, CoreError> {
        let main = safe_rel_file(&self.main_file)?;
        let base = Path::new(&main).file_stem().unwrap_or_default();
        let name = format!("{}.{ext}", base.to_string_lossy());
        Ok(build.join(name))
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
    /// The volume and file number of the folder shell escape was granted for: a copy of the
    /// folder, or of this file in another, isn't trusted.
    #[serde(rename = "shellEscapeFor", skip_serializing_if = "Option::is_none")]
    shell_escape_for: Option<(u64, u64)>,
    /// A newer build's, or another tool's: a write keeps them, as a synced folder shares the file.
    #[serde(flatten)]
    rest: Map<String, Value>,
}

/// Far more than settings take: a file that size, as a folder opened may hold, isn't theirs,
/// and Home reads each project's.
const MAX_FILE: u64 = 1 << 20;

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
    let mut bytes = Vec::new();
    match fs::File::open(path) {
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(T::default()),
        opened => opened
            .and_then(|file| file.take(MAX_FILE + 1).read_to_end(&mut bytes))
            .map_err(|err| unreadable(CoreError::from(err).message))?,
    };
    if bytes.len() as u64 > MAX_FILE {
        return Err(unreadable("it's over 1 MB".into()));
    }
    serde_json::from_slice(&bytes).map_err(|err| unreadable(err.to_string()))
}

fn update<T: DeserializeOwned + Default + Serialize>(
    path: &Path,
    change: impl FnOnce(&mut T) -> Result<(), CoreError>,
) -> Result<T, CoreError> {
    let mut value = load(path)?;
    change(&mut value)?;
    let bytes =
        serde_json::to_vec_pretty(&value).map_err(|e| CoreError::internal(e.to_string()))?;
    atomic::write(path, &bytes)?;
    Ok(value)
}

fn read_project(file: &Path) -> ProjectFile {
    load(file).unwrap_or_default()
}

pub fn read_settings(file: &Path) -> Settings {
    read_project(file).settings
}

/// The settings a project's files may hold; `shellEscape` in `patch` is left to `grant`.
pub fn write_settings(file: &Path, patch: &Value) -> Result<Settings, CoreError> {
    let file = update(file, |file: &mut ProjectFile| {
        let mut settings = merged(&file.settings, patch, "settings")?;
        // latexmk would read a main file starting with "-" as an option.
        settings.main_file = safe_rel_file(&settings.main_file)?;
        file.settings = settings;
        // An older build's grant, which a file shared with the folder could give.
        file.rest.remove("shellEscape");
        Ok(())
    })?;
    Ok(file.settings)
}

/// Whether the user let the project's documents run programs (`-shell-escape`), which also
/// reads its own latexmkrc.
pub fn granted(project: &Project) -> bool {
    let granted = read_project(&project.ui).shell_escape_for;
    granted.is_some_and(|folder| identity(&project.root) == Some(folder))
}

pub fn grant(project: &Project, on: bool) -> Result<(), CoreError> {
    update(&project.ui, |file: &mut ProjectFile| {
        file.shell_escape_for = on.then(|| identity(&project.root)).flatten();
        Ok(())
    })
    .map(drop)
}

/// The settings as a host shows them, with whether shell escape is granted.
pub fn shown(project: &Project) -> Value {
    let settings = read_settings(&project.settings);
    let mut shown = serde_json::to_value(settings).expect("settings as JSON");
    shown["shellEscape"] = granted(project).into();
    shown
}

/// `value` with the keys of `patch` in place of its own: 400 if the patch isn't an object or
/// what it makes isn't a `T`.
fn merged<T: Serialize + DeserializeOwned>(
    value: &T,
    patch: &Value,
    what: &str,
) -> Result<T, CoreError> {
    let Value::Object(patch) = patch else {
        return Err(CoreError::bad_request(format!("Invalid {what}")));
    };
    let Ok(Value::Object(mut merged)) = serde_json::to_value(value) else {
        unreachable!("{what} serialize as an object");
    };
    merged.extend(patch.clone());
    T::deserialize(Value::Object(merged))
        .map_err(|err| CoreError::bad_request(format!("Invalid {what}: {err}")))
}

/// The folders chosen for TeX's programs and for TeXpresso, shared by every project; None finds the program itself.
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
        update(&data_dir.join(APP_SETTINGS_FILE), |app| {
            change(app);
            Ok(())
        })
        .map(drop)
    }
}

/// What a host keeps of the project's interface: the place it was left at, which a host shows
/// again as the project opens, and whether Live Preview was last asked to run.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UiState {
    pub expanded_folders: Vec<String>,
    pub folded_headings: Vec<String>,
    pub file: Option<String>,
    pub line: Option<u32>,
    pub page: Option<u32>,
    /// The host's alone, kept as it sends it.
    pub zoom: Option<Value>,
    pub panel: bool,
    pub live_preview: bool,
    /// A newer build's, kept as the project file's are.
    #[serde(flatten)]
    pub rest: Map<String, Value>,
}

pub fn read_ui(file: &Path) -> UiState {
    read_project(file).ui
}

pub(crate) fn store_ui(
    file: &Path,
    change: impl FnOnce(&mut UiState) -> Result<(), CoreError>,
) -> Result<UiState, CoreError> {
    let file = update(file, |file: &mut ProjectFile| {
        change(&mut file.ui)?;
        for list in [&mut file.ui.expanded_folders, &mut file.ui.folded_headings] {
            list.sort();
            list.dedup();
        }
        Ok(())
    })?;
    Ok(file.ui)
}

/// The keys of `patch` replace the state's, but for `livePreview`, which only the core's Live
/// Preview commands write.
pub fn write_ui(file: &Path, patch: &Value) -> Result<UiState, CoreError> {
    store_ui(file, |state| {
        let live_preview = state.live_preview;
        *state = UiState {
            live_preview,
            ..merged(state, patch, "ui state")?
        };
        Ok(())
    })
}

/// Move the saved state of a renamed entry with it, as `moved` gives each
/// project path's new one (None: unmoved): folders by their path, folds by the
/// file their key starts with. Best effort: the state is a convenience.
pub(crate) fn move_ui(file: &Path, moved: impl Fn(&str) -> Option<String>) {
    let before = read_ui(file);
    let mut state = before.clone();
    for folder in &mut state.expanded_folders {
        if let Some(new) = moved(folder) {
            *folder = new;
        }
    }
    if let Some(shown) = &mut state.file
        && let Some(new) = moved(shown)
    {
        *shown = new;
    }
    for key in &mut state.folded_headings {
        if let Some((file, rest)) = key.split_once('\t')
            && let Some(new) = moved(file)
        {
            *key = format!("{new}\t{rest}");
        }
    }
    if state != before {
        let _ = store_ui(file, |saved| {
            *saved = state;
            Ok(())
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::projects::testing::project;
    use crate::{BUILD_DIR, SETTINGS_FILE};
    use serde_json::json;

    #[test]
    fn a_settings_patch_changes_only_its_keys_and_returns_what_a_later_read_sees() {
        let (_dir, root) = project();
        let file = root.join(SETTINGS_FILE);
        fs::write(&file, r#"{ "engine": "xelatex" }"#).unwrap();
        let written =
            write_settings(&file, &json!({ "stopOnFirstError": true, "unknown": 1 })).unwrap();
        let expected = json!({
            "mainFile": "main.tex", "engine": "xelatex", "stopOnFirstError": true
        });
        assert_eq!(json!(written), expected);
        assert_eq!(json!(read_settings(&file)), expected);

        let before = fs::read(&file).unwrap();
        for (bad, why) in [
            (json!({ "engine": "word" }), "unknown variant"),
            (
                json!({ "mainFile": "-interaction.tex" }),
                "Path segments cannot start",
            ),
            (json!([1]), "Invalid settings"),
        ] {
            let err = write_settings(&file, &bad).unwrap_err();
            assert_eq!(err.kind, crate::ErrorKind::Invalid, "{}", err.message);
            assert!(err.message.contains(why), "{:?} lacks {why:?}", err.message);
        }
        assert_eq!(fs::read(&file).unwrap(), before);

        let settings = write_settings(&file, &json!({ "mainFile": "chapters/paper.tex" })).unwrap();
        let pdf = settings.output(&root.join(BUILD_DIR), "pdf").unwrap();
        assert_eq!(pdf, root.join(BUILD_DIR).join("paper.pdf"));
    }

    #[test]
    fn shell_escape_is_the_apps_grant_to_one_folder_and_no_file_in_it_gives_it() {
        let (dir, root) = project();
        let project = Project::in_folder(&root);
        fs::write(&project.settings, r#"{ "shellEscape": true }"#).unwrap();
        assert!(!granted(&project));
        grant(&project, true).unwrap();
        assert_eq!(shown(&project)["shellEscape"], true);
        write_settings(&project.settings, &json!({ "engine": "lualatex" })).unwrap();
        let file: Value = serde_json::from_slice(&fs::read(&project.settings).unwrap()).unwrap();
        assert_eq!(file.get("shellEscape"), None);

        // A folder moved keeps it; a copy of its file, as a duplicate or download has, doesn't.
        let moved = dir.path().join("Moved");
        fs::rename(&root, &moved).unwrap();
        assert!(granted(&Project::in_folder(&moved)));
        fs::create_dir(&root).unwrap();
        fs::copy(moved.join(SETTINGS_FILE), &project.settings).unwrap();
        assert!(!granted(&project));

        let moved = Project::in_folder(&moved);
        grant(&moved, false).unwrap();
        assert!(!granted(&moved));
    }

    #[test]
    fn a_ui_patch_replaces_only_what_it_names_and_never_live_preview() {
        let dir = tempfile::tempdir().unwrap();
        let file = &dir.path().join(SETTINGS_FILE);
        assert_eq!(read_ui(file), UiState::default());
        let place = json!({
            "expandedFolders": ["b", "a", "b"], "file": "a.tex", "line": 12, "zoom": "fitWidth"
        });
        write_ui(file, &place).unwrap();
        store_ui(file, |ui| {
            ui.live_preview = true;
            Ok(())
        })
        .unwrap();
        write_settings(file, &json!({ "engine": "lualatex" })).unwrap();
        let patch = json!({
            "line": null, "page": 3, "zoom": 1.5, "panel": true, "livePreview": false
        });
        let written = write_ui(file, &patch).unwrap();
        let expected = json!({
            "expandedFolders": ["a", "b"], "foldedHeadings": [], "file": "a.tex", "line": null,
            "page": 3, "zoom": 1.5, "panel": true, "livePreview": true
        });
        assert_eq!(json!(written), expected);
        assert_eq!(json!(read_ui(file)), expected);
        assert_eq!(read_settings(file).engine, Engine::Lualatex);
    }

    #[test]
    fn a_write_keeps_the_keys_a_newer_build_wrote() {
        let dir = tempfile::tempdir().unwrap();
        let file = &dir.path().join(SETTINGS_FILE);
        let newer =
            r#"{ "mainFile": "a.tex", "outline": 2, "ui": { "panel": true, "split": 0.4 } }"#;
        fs::write(file, newer).unwrap();
        write_ui(file, &json!({ "line": 3 })).unwrap();
        write_settings(file, &json!({ "engine": "xelatex" })).unwrap();
        let written: Value = serde_json::from_slice(&fs::read(file).unwrap()).unwrap();
        assert_eq!(
            (&written["outline"], &written["ui"]["split"]),
            (&json!(2), &json!(0.4))
        );
    }

    #[test]
    fn a_settings_file_that_cannot_be_read_is_never_written_over() {
        let dir = tempfile::tempdir().unwrap();
        let (root, file) = (dir.path(), dir.path().join(SETTINGS_FILE));
        let app_file = root.join(APP_SETTINGS_FILE);
        let broken = "{ \"mainFile\": \"thesis.tex\", }";
        fs::write(&file, broken).unwrap();
        fs::write(&app_file, broken).unwrap();
        let err = write_settings(&file, &json!({ "engine": "lualatex" })).unwrap_err();
        assert_eq!(err.kind, crate::ErrorKind::Conflict);
        assert!(err.message.contains(SETTINGS_FILE), "{}", err.message);
        let chosen = AppSettings::update(root, |app| app.tex_dir = Some("/tex".into()));
        assert_eq!(chosen.unwrap_err().kind, crate::ErrorKind::Conflict);
        assert_eq!(fs::read_to_string(&file).unwrap(), broken);
        assert_eq!(fs::read_to_string(&app_file).unwrap(), broken);
        assert_eq!(read_settings(&file).main_file, "main.tex");
        assert_eq!(AppSettings::read(root).tex_dir, None);

        // Nor is one too large to be settings read whole.
        fs::File::create(&file)
            .unwrap()
            .set_len(MAX_FILE + 1)
            .unwrap();
        let err = write_settings(&file, &json!({})).unwrap_err();
        assert!(err.message.contains("over 1 MB"), "{}", err.message);
    }
}
