//! Per-project settings in `<project>/.texlocal.json`, ported from
//! server/projects.js. Settings arrive from the UI, and two of them are
//! dangerous taken as given: `mainFile` becomes an argv element for latexmk,
//! and `shellEscape` turns on arbitrary shell execution during a compile.
//! Only known keys are accepted, each validated rather than merged as sent.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::CoreError;
use crate::paths::safe_rel_file;
use crate::{BUILD_DIR, SETTINGS_FILE};

pub const ENGINES: &[&str] = &["pdflatex", "xelatex", "lualatex"];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub main_file: String,
    pub engine: String,
    pub shell_escape: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            main_file: "main.tex".into(),
            engine: "pdflatex".into(),
            shell_escape: false,
        }
    }
}

fn read_raw(root: &Path) -> Map<String, Value> {
    fs::read(root.join(SETTINGS_FILE))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Map<String, Value>>(&bytes).ok())
        .unwrap_or_default()
}

/// Lenient read: defaults fill in anything missing or mistyped. Validation of
/// the values happens where they are used (compile re-checks both mainFile and
/// engine), because the file on disk is user-editable.
pub fn read_settings(root: &Path) -> Settings {
    let raw = read_raw(root);
    let defaults = Settings::default();
    Settings {
        main_file: raw
            .get("mainFile")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or(defaults.main_file),
        engine: raw
            .get("engine")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or(defaults.engine),
        shell_escape: raw
            .get("shellEscape")
            .and_then(Value::as_bool)
            .unwrap_or(defaults.shell_escape),
    }
}

/// The validated subset of a settings patch. (projects.js `validateSettings`)
fn validate_settings(root: &Path, patch: &Value) -> Result<Map<String, Value>, CoreError> {
    let obj = match patch {
        Value::Object(o) => o,
        _ => return Err(CoreError::bad_request("Invalid settings")),
    };
    let mut out = Map::new();
    if let Some(engine) = obj.get("engine") {
        match engine.as_str() {
            Some(e) if ENGINES.contains(&e) => {
                out.insert("engine".into(), Value::String(e.into()));
            }
            _ => return Err(CoreError::bad_request(format!("Unknown engine: {engine}"))),
        }
    }
    if let Some(se) = obj.get("shellEscape") {
        match se {
            Value::Bool(b) => {
                out.insert("shellEscape".into(), Value::Bool(*b));
            }
            _ => return Err(CoreError::bad_request("shellEscape must be a boolean")),
        }
    }
    if let Some(mf) = obj.get("mainFile") {
        let rel = match mf.as_str() {
            Some(s) => safe_rel_file(root, s)?,
            None => return Err(CoreError::bad_request("Missing path")),
        };
        out.insert("mainFile".into(), Value::String(rel));
    }
    Ok(out)
}

/// Merge a validated patch over current settings (unknown keys in the file are
/// preserved, as the JS spread did) and write the result.
pub fn write_settings(root: &Path, patch: &Value) -> Result<Settings, CoreError> {
    let validated = validate_settings(root, patch)?;
    let mut merged = serde_json::to_value(Settings::default())
        .ok()
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    for (k, v) in read_raw(root) {
        merged.insert(k, v);
    }
    for (k, v) in validated {
        merged.insert(k, v);
    }
    let text = serde_json::to_string_pretty(&Value::Object(merged))
        .map_err(|e| CoreError::internal(e.to_string()))?;
    fs::write(root.join(SETTINGS_FILE), text)?;
    Ok(read_settings(root))
}

/// The compiled PDF path for a project — the ONE place this is derived.
/// mainFile "paper.tex" → "<root>/build/paper.pdf". (projects.js
/// `compiledPdfPath`)
pub fn compiled_pdf_path(root: &Path) -> Result<PathBuf, CoreError> {
    let settings = read_settings(root);
    let rel = safe_rel_file(root, &settings.main_file)?;
    let base = main_base_name(&rel);
    Ok(root.join(BUILD_DIR).join(format!("{base}.pdf")))
}

/// The main file's name without its extension ("chapters/paper.tex" → "paper").
pub fn main_base_name(rel_slash: &str) -> String {
    let name = rel_slash.rsplit('/').next().unwrap_or(rel_slash);
    Path::new(name)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| name.to_string())
}
