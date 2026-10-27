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
pub struct ProjectSettings {
    pub main_file: String,
    pub engine: Engine,
    pub stop_on_first_error: bool,
}

impl Default for ProjectSettings {
    fn default() -> Self {
        Self {
            main_file: "main.tex".into(),
            engine: Engine::default(),
            stop_on_first_error: false,
        }
    }
}

impl ProjectSettings {
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

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct ProjectFile {
    #[serde(flatten)]
    settings: ProjectSettings,
    ui: UiState,
    #[serde(rename = "shellEscapeFor", skip_serializing_if = "Option::is_none")]
    shell_escape_for: Option<(u64, u64)>,
    #[serde(flatten)]
    rest: Map<String, Value>,
}

const MAX_FILE: u64 = 1 << 20;

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

pub fn read_settings(file: &Path) -> ProjectSettings {
    read_project(file).settings
}

pub fn write_settings(file: &Path, patch: &Value) -> Result<ProjectSettings, CoreError> {
    let file = update(file, |file: &mut ProjectFile| {
        let mut settings = merged(&file.settings, patch, "settings")?;
        settings.main_file = safe_rel_file(&settings.main_file)?;
        file.settings = settings;
        file.rest.remove("shellEscape");
        Ok(())
    })?;
    Ok(file.settings)
}

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

pub fn shown(project: &Project) -> Value {
    let settings = read_settings(&project.settings);
    let mut shown = serde_json::to_value(settings).expect("settings as JSON");
    shown["shellEscape"] = granted(project).into();
    shown
}

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

#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UiState {
    pub expanded_folders: Vec<String>,
    pub folded_headings: Vec<String>,
    pub file: Option<String>,
    pub line: Option<u32>,
    pub page: Option<u32>,
    pub zoom: Option<Value>,
    pub panel: bool,
    pub live_preview: bool,
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
