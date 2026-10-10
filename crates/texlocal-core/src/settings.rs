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

/// Merge known, validated patch keys over current settings, preserving unknown
/// keys in the file. Validate before the atomic write.
pub fn write_settings(root: &Path, patch: &Value) -> Result<Settings, CoreError> {
    let Value::Object(obj) = patch else {
        return Err(CoreError::bad_request("Invalid settings"));
    };
    let Value::Object(mut merged) = serde_json::to_value(Settings::default()).unwrap() else {
        unreachable!("Settings serializes as an object");
    };
    merged.extend(read_object(&root.join(SETTINGS_FILE)));
    match obj.get("engine") {
        None => {}
        Some(Value::String(e)) if engine_flags(e).is_some() => {
            merged.insert("engine".into(), e.as_str().into());
        }
        // A string's contents, not its JSON encoding: quotes would otherwise
        // reach the user's toast.
        Some(Value::String(e)) => {
            return Err(CoreError::bad_request(format!("Unknown engine: {e}")))
        }
        Some(other) => return Err(CoreError::bad_request(format!("Unknown engine: {other}"))),
    }
    for key in ["shellEscape", "stopOnFirstError"] {
        match obj.get(key) {
            None => {}
            Some(Value::Bool(b)) => {
                merged.insert(key.into(), (*b).into());
            }
            Some(_) => return Err(CoreError::bad_request(format!("{key} must be a boolean"))),
        }
    }
    if let Some(mf) = obj.get("mainFile") {
        let mf = mf
            .as_str()
            .ok_or_else(|| CoreError::bad_request("Missing path"))?;
        merged.insert("mainFile".into(), safe_rel_file(root, mf)?.into());
    }
    let bytes =
        serde_json::to_vec_pretty(&merged).map_err(|e| CoreError::internal(e.to_string()))?;
    atomic::write(&root.join(SETTINGS_FILE), &bytes)?;
    // What was just written, without reading it back.
    Ok(lenient(&merged))
}

/// The compiled PDF path for a project — the ONE place this is derived.
/// mainFile "paper.tex" → "<root>/build/paper.pdf".
pub fn compiled_pdf_path(root: &Path) -> Result<PathBuf, CoreError> {
    let settings = read_settings(root);
    let base = main_base_name(&safe_rel_file(root, &settings.main_file)?);
    Ok(root.join(BUILD_DIR).join(format!("{base}.pdf")))
}

/// The main file's name without its extension ("chapters/paper.tex" → "paper").
pub fn main_base_name(rel_slash: &str) -> String {
    Path::new(rel_slash)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| rel_slash.to_string())
}
