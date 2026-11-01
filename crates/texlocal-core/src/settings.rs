use std::fs;
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

use schemars::JsonSchema;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use texlocal_latex::message::Message;

use crate::atomic::{self, Flush};
use crate::error::CoreError;
use crate::messages;
use crate::paths::{Project, identity, safe_rel_file};

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StoredSettings {
    pub main_file: String,
    pub engine: Engine,
    pub stop_on_first_error: bool,
}

impl Default for StoredSettings {
    fn default() -> Self {
        Self {
            main_file: "main.tex".into(),
            engine: Engine::default(),
            stop_on_first_error: false,
        }
    }
}

impl StoredSettings {
    pub fn output(&self, build: &Path, ext: &str) -> Result<PathBuf, CoreError> {
        let main = safe_rel_file(&self.main_file)?;
        let base = Path::new(&main).file_stem().unwrap_or_default();
        let name = format!("{}.{ext}", base.to_string_lossy());
        Ok(build.join(name))
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum Engine {
    #[default]
    #[schemars(title = "pdfLaTeX")]
    Pdflatex,
    #[schemars(title = "XeLaTeX")]
    Xelatex,
    #[schemars(title = "LuaLaTeX")]
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
    settings: StoredSettings,
    #[serde(flatten)]
    rest: Map<String, Value>,
}

#[derive(Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
struct DeviceFile {
    #[serde(skip_serializing_if = "StoredUi::is_default")]
    ui: StoredUi,
    #[serde(rename = "shellEscapeFor", skip_serializing_if = "Option::is_none")]
    shell_escape_for: Option<(u64, u64)>,
    #[serde(flatten)]
    rest: Map<String, Value>,
}

const MAX_FILE: u64 = 1 << 20;

fn load<T: DeserializeOwned + Default>(path: &Path) -> Result<T, CoreError> {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let unreadable = |why: Message| CoreError::conflict(messages::unreadable(&name, why));
    let mut bytes = Vec::new();
    match fs::File::open(path) {
        Err(err) if err.kind() == ErrorKind::NotFound => return Ok(T::default()),
        opened => opened
            .and_then(|file| file.take(MAX_FILE + 1).read_to_end(&mut bytes))
            .map_err(|err| unreadable(CoreError::from(err).message))?,
    };
    if bytes.len() as u64 > MAX_FILE {
        return Err(unreadable(messages::over_one_mb()));
    }
    serde_json::from_slice(&bytes).map_err(|err| unreadable(messages::unexpected(err)))
}

fn update<T: DeserializeOwned + Default + Serialize>(
    path: &Path,
    change: impl FnOnce(&mut T) -> Result<(), CoreError>,
) -> Result<T, CoreError> {
    let mut value = load(path)?;
    change(&mut value)?;
    let bytes = serde_json::to_vec_pretty(&value)
        .map_err(|e| CoreError::internal(messages::unexpected(e)))?;
    atomic::write(path, &bytes, Flush::Full)?;
    Ok(value)
}

fn read_device(file: &Path) -> DeviceFile {
    load(file).unwrap_or_default()
}

fn update_device(
    file: &Path,
    change: impl FnOnce(&mut DeviceFile) -> Result<(), CoreError>,
) -> Result<(), CoreError> {
    match fs::create_dir(file.parent().expect("a file is in a folder")) {
        Err(err) if err.kind() != ErrorKind::AlreadyExists => Err(err.into()),
        _ => update(file, change).map(drop),
    }
}

pub(crate) fn migrate(project: &Project) {
    if project.ui == project.settings || project.ui.exists() {
        return;
    }
    let Ok(old) = load::<DeviceFile>(&project.settings) else {
        return;
    };
    let moved = DeviceFile {
        rest: Map::new(),
        ..old
    };
    if moved != DeviceFile::default() {
        let _ = update_device(&project.ui, |device| {
            *device = moved;
            Ok(())
        });
    }
}

pub(crate) fn copy_ui(from: &Project, to: &Path) {
    migrate(from);
    if let Ok(device) = load::<DeviceFile>(&from.ui) {
        let _ = update_device(to, |copy| {
            *copy = DeviceFile {
                shell_escape_for: None,
                ..device
            };
            Ok(())
        });
    }
}

pub fn read_settings(file: &Path) -> StoredSettings {
    load::<ProjectFile>(file).unwrap_or_default().settings
}

pub fn write_settings(
    project: &Project,
    patch: &SettingsPatch,
) -> Result<StoredSettings, CoreError> {
    let moved = project.ui != project.settings && project.ui.exists();
    store_settings(&project.settings, patch, moved)
}

pub(crate) fn new_settings(file: &Path, patch: &SettingsPatch) -> Result<(), CoreError> {
    store_settings(file, patch, false).map(drop)
}

fn store_settings(
    file: &Path,
    patch: &SettingsPatch,
    moved: bool,
) -> Result<StoredSettings, CoreError> {
    let file = update(file, |file: &mut ProjectFile| {
        let settings = &mut file.settings;
        if let Some(main_file) = &patch.main_file {
            settings.main_file = safe_rel_file(main_file)?;
        }
        settings.engine = patch.engine.unwrap_or(settings.engine);
        settings.stop_on_first_error = patch
            .stop_on_first_error
            .unwrap_or(settings.stop_on_first_error);
        file.rest.remove("shellEscape");
        if moved {
            file.rest.remove("ui");
            file.rest.remove("shellEscapeFor");
        }
        Ok(())
    })?;
    Ok(file.settings)
}

pub fn problem(project: &Project) -> Option<Message> {
    let problem = load::<ProjectFile>(&project.settings).err();
    let problem = problem.or_else(|| load::<DeviceFile>(&project.ui).err());
    problem.map(|err| err.message)
}

pub fn granted(project: &Project) -> bool {
    let granted = read_device(&project.ui).shell_escape_for;
    granted.is_some_and(|folder| identity(&project.root) == Some(folder))
}

pub fn grant(project: &Project, on: bool) -> Result<(), CoreError> {
    update_device(&project.ui, |device| {
        device.shell_escape_for = on.then(|| identity(&project.root)).flatten();
        Ok(())
    })
}

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProjectSettings {
    main_file: String,
    engine: Engine,
    stop_on_first_error: bool,
    shell_escape: bool,
}

pub fn shown(project: &Project, main: Option<String>) -> ProjectSettings {
    let StoredSettings {
        main_file,
        engine,
        stop_on_first_error,
    } = read_settings(&project.settings);
    ProjectSettings {
        main_file: main.unwrap_or(main_file),
        engine,
        stop_on_first_error,
        shell_escape: granted(project),
    }
}

#[derive(Default, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsPatch {
    pub main_file: Option<String>,
    pub engine: Option<Engine>,
    pub stop_on_first_error: Option<bool>,
    pub shell_escape: Option<bool>,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct AppSettings {
    pub tex_dir: Option<PathBuf>,
    pub texpresso_dir: Option<PathBuf>,
    #[serde(flatten)]
    rest: Map<String, Value>,
}

pub(crate) const APP_SETTINGS_FILE: &str = ".texlocal-app.json";

impl AppSettings {
    pub(crate) fn read(dir: &Path) -> Self {
        load(&dir.join(APP_SETTINGS_FILE)).unwrap_or_default()
    }

    pub(crate) fn update(dir: &Path, change: impl FnOnce(&mut Self)) -> Result<(), CoreError> {
        update(&dir.join(APP_SETTINGS_FILE), |app| {
            change(app);
            Ok(())
        })
        .map(drop)
    }
}

#[derive(Default, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StoredUi {
    pub expanded_folders: Vec<String>,
    pub folded_headings: Vec<String>,
    pub file: Option<String>,
    pub line: Option<u32>,
    pub zoom: Option<Value>,
    pub pdf_place: Option<PdfPlace>,
    pub live_preview: bool,
    #[serde(flatten)]
    pub rest: Map<String, Value>,
}

impl StoredUi {
    fn is_default(&self) -> bool {
        *self == Self::default()
    }
}

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UiState {
    expanded_folders: Vec<String>,
    folded_headings: Vec<String>,
    pub(crate) file: Option<String>,
    line: Option<u32>,
    zoom: Option<Zoom>,
    pdf_place: Option<PdfPlace>,
    #[serde(skip)]
    pub(crate) live_preview: bool,
}

// The page is a 0-based index, and x and y are the top-left of the shown area in its PDF space.
#[derive(Clone, Copy, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PdfPlace {
    page: u32,
    x: f64,
    y: f64,
}

pub fn read_ui(file: &Path) -> UiState {
    let ui = read_device(file).ui;
    UiState {
        zoom: ui.zoom.as_ref().and_then(Zoom::read),
        expanded_folders: ui.expanded_folders,
        folded_headings: ui.folded_headings,
        file: ui.file,
        line: ui.line,
        pdf_place: ui.pdf_place,
        live_preview: ui.live_preview,
    }
}

pub(crate) fn store_ui(
    file: &Path,
    change: impl FnOnce(&mut StoredUi) -> Result<(), CoreError>,
) -> Result<(), CoreError> {
    update_device(file, |device| {
        let ui = &mut device.ui;
        change(ui)?;
        for list in [&mut ui.expanded_folders, &mut ui.folded_headings] {
            list.sort();
            list.dedup();
        }
        Ok(())
    })
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UiPatch {
    expanded_folders: Option<Vec<String>>,
    folded_headings: Option<Vec<String>>,
    place: Option<UiPlace>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UiPlace {
    file: Option<String>,
    line: Option<u32>,
    zoom: Option<Zoom>,
    pdf_place: Option<PdfPlace>,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum Zoom {
    FitWidth,
    FitPage,
    Scale(f64),
}

impl Zoom {
    fn stored(self) -> Value {
        match self {
            Self::FitWidth => "fitWidth".into(),
            Self::FitPage => "fitPage".into(),
            Self::Scale(scale) => scale.into(),
        }
    }

    fn read(stored: &Value) -> Option<Self> {
        match stored {
            Value::Number(scale) => scale.as_f64().map(Self::Scale),
            Value::String(fit) if fit == "fitPage" => Some(Self::FitPage),
            Value::String(_) => Some(Self::FitWidth),
            _ => None,
        }
    }
}

pub fn write_ui(file: &Path, patch: UiPatch) -> Result<(), CoreError> {
    store_ui(file, |state| {
        let UiPatch {
            expanded_folders,
            folded_headings,
            place,
        } = patch;
        if let Some(folders) = expanded_folders {
            state.expanded_folders = folders;
        }
        if let Some(headings) = folded_headings {
            state.folded_headings = headings;
        }
        if let Some(UiPlace {
            file,
            line,
            zoom,
            pdf_place,
        }) = place
        {
            (state.file, state.line) = (file, line);
            (state.zoom, state.pdf_place) = (zoom.map(Zoom::stored), pdf_place);
        }
        Ok(())
    })
}

pub(crate) fn move_ui(file: &Path, moved: impl Fn(&str) -> Option<String>) {
    let before = read_device(file).ui;
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
