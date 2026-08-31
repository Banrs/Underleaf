//! The command surface, one-for-one with the 22 IPC channels that
//! electron/main.mjs exposed. Every path argument goes through the core's
//! guards; nothing here reimplements them.

use std::path::PathBuf;
use std::time::Instant;

use serde::Serialize;
use serde_json::Value;
use tauri::ipc::{InvokeBody, Request};
use tauri::{AppHandle, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

use texlocal_core::compile::{CompileOverrides, CompileResult, TexStatus};
use texlocal_core::projects::{self, ProjectInfo, RenameResult, SearchHit, Symbols, TreeNode};
use texlocal_core::settings::{self, Settings};
use texlocal_core::synctex::{self, ForwardLoc, InverseLoc};
use texlocal_core::{compile as core_compile, paths, zipexport};

use crate::error::{CmdError, CmdResult};
use crate::state::AppState;

const UPLOAD_MAX_BYTES: usize = 100 * 1024 * 1024;

fn root(state: &AppState, id: &str) -> CmdResult<PathBuf> {
    Ok(paths::project_root(&state.data_dir, id)?)
}

#[derive(Serialize)]
pub struct WriteAck {
    pub ok: bool,
}

#[derive(Serialize)]
pub struct FileText {
    pub text: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Saved {
    pub saved: Vec<String>,
}

#[derive(Serialize)]
pub struct DialogOutcome {
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub ok: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub canceled: bool,
}

impl DialogOutcome {
    fn done() -> Self {
        Self {
            ok: true,
            canceled: false,
        }
    }
    fn canceled() -> Self {
        Self {
            ok: false,
            canceled: true,
        }
    }
}

// ---------- status ----------

#[tauri::command]
pub async fn status(state: State<'_, AppState>) -> CmdResult<TexStatus> {
    if let Some(cached) = state.cached_status() {
        return Ok(cached);
    }
    let found = core_compile::tex_available(None).await;
    state.store_status(found.clone(), Instant::now());
    Ok(found)
}

// ---------- projects ----------

#[tauri::command]
pub fn list_projects(state: State<'_, AppState>) -> CmdResult<Vec<ProjectInfo>> {
    Ok(projects::list_projects(&state.data_dir)?)
}

#[tauri::command]
pub fn create_project(
    state: State<'_, AppState>,
    name: String,
    template: Option<String>,
) -> CmdResult<ProjectInfo> {
    Ok(projects::create_project(
        &state.data_dir,
        &name,
        template.as_deref().unwrap_or("article"),
    )?)
}

#[tauri::command]
pub fn rename_project(
    state: State<'_, AppState>,
    id: String,
    name: String,
) -> CmdResult<ProjectInfo> {
    let old = root(&state, &id)?;
    let info = projects::rename_project(&state.data_dir, &id, &name)?;
    state.forget_project(&old);
    Ok(info)
}

#[tauri::command]
pub fn delete_project(state: State<'_, AppState>, id: String) -> CmdResult<()> {
    let old = root(&state, &id)?;
    projects::delete_project(&state.data_dir, &id)?;
    state.forget_project(&old);
    Ok(())
}

// ---------- settings ----------

#[tauri::command]
pub fn get_settings(state: State<'_, AppState>, id: String) -> CmdResult<Settings> {
    Ok(settings::read_settings(&root(&state, &id)?))
}

#[tauri::command]
pub fn set_settings(state: State<'_, AppState>, id: String, patch: Value) -> CmdResult<Settings> {
    Ok(settings::write_settings(&root(&state, &id)?, &patch)?)
}

// ---------- files ----------

#[tauri::command]
pub fn file_tree(state: State<'_, AppState>, id: String) -> CmdResult<Vec<TreeNode>> {
    Ok(projects::file_tree(&root(&state, &id)?)?)
}

#[tauri::command]
pub fn scan_symbols(state: State<'_, AppState>, id: String) -> CmdResult<Symbols> {
    let root = root(&state, &id)?;
    let stamps = projects::symbols_fingerprint(&root)?;
    if let Some(cached) = state.cached_symbols(&root, &stamps) {
        return Ok(cached);
    }
    let symbols = projects::scan_symbols(&root)?;
    state.store_symbols(&root, stamps, symbols.clone());
    Ok(symbols)
}

#[tauri::command]
pub fn search_project(
    state: State<'_, AppState>,
    id: String,
    query: String,
) -> CmdResult<Vec<SearchHit>> {
    Ok(projects::search_project(&root(&state, &id)?, &query, 100)?)
}

#[tauri::command]
pub fn read_file(state: State<'_, AppState>, id: String, path: String) -> CmdResult<FileText> {
    let abs = paths::safe_path(&root(&state, &id)?, &path)?;
    let bytes = std::fs::read(abs)?;
    Ok(FileText {
        text: String::from_utf8_lossy(&bytes).into_owned(),
    })
}

#[tauri::command]
pub fn write_file(
    state: State<'_, AppState>,
    id: String,
    path: String,
    text: Option<String>,
) -> CmdResult<WriteAck> {
    let abs = paths::safe_path(&root(&state, &id)?, &path)?;
    if let Some(parent) = abs.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(abs, text.unwrap_or_default())?;
    Ok(WriteAck { ok: true })
}

#[tauri::command]
pub fn create_entry(
    state: State<'_, AppState>,
    id: String,
    path: String,
    dir: Option<bool>,
) -> CmdResult<()> {
    Ok(projects::create_file(
        &root(&state, &id)?,
        &path,
        dir.unwrap_or(false),
    )?)
}

#[tauri::command]
pub fn rename_entry(
    state: State<'_, AppState>,
    id: String,
    from: String,
    to: String,
) -> CmdResult<RenameResult> {
    Ok(projects::rename_entry(&root(&state, &id)?, &from, &to)?)
}

#[tauri::command]
pub fn delete_entry(state: State<'_, AppState>, id: String, path: String) -> CmdResult<()> {
    Ok(projects::delete_entry(&root(&state, &id)?, &path)?)
}

/// One file per invoke, body sent raw. The metadata rides in percent-encoded
/// headers because the body is the file itself — serializing bytes as a JSON
/// number array (what the Electron path did) costs several times the payload.
#[tauri::command]
pub fn upload_file(state: State<'_, AppState>, request: Request<'_>) -> CmdResult<Saved> {
    let header = |name: &str| -> CmdResult<String> {
        let raw = request
            .headers()
            .get(name)
            .ok_or_else(|| CmdError(format!("Missing {name} header")))?
            .to_str()
            .map_err(|_| CmdError(format!("Invalid {name} header")))?;
        Ok(percent_encoding::percent_decode_str(raw)
            .decode_utf8_lossy()
            .into_owned())
    };

    let InvokeBody::Raw(bytes) = request.body() else {
        return Err(CmdError("Upload body must be raw bytes".into()));
    };
    if bytes.len() > UPLOAD_MAX_BYTES {
        return Err(CmdError(format!(
            "File exceeds the {} MB upload limit",
            UPLOAD_MAX_BYTES / 1024 / 1024
        )));
    }

    let root = root(&state, &header("x-project")?)?;
    let dir = header("x-dir")?;
    let name = header("x-path")?.replace('\\', "/");
    let rel = if dir.is_empty() {
        name
    } else {
        format!("{}/{}", dir.trim_end_matches('/'), name)
    };

    let abs = paths::safe_path(&root, &rel)?;
    if let Some(parent) = abs.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(abs, bytes)?;
    Ok(Saved { saved: vec![rel] })
}

// ---------- compile / synctex ----------

#[tauri::command]
pub async fn compile(
    state: State<'_, AppState>,
    id: String,
    options: Option<CompileOverrides>,
) -> CmdResult<CompileResult> {
    let root = root(&state, &id)?;
    Ok(state
        .compile
        .compile(&root, &options.unwrap_or_default())
        .await?)
}

#[tauri::command]
pub async fn synctex_forward(
    state: State<'_, AppState>,
    id: String,
    file: String,
    line: u32,
) -> CmdResult<ForwardLoc> {
    let root = root(&state, &id)?;
    Ok(synctex::synctex_forward(&root, &file, line, core_compile::tex_path()).await?)
}

#[tauri::command]
pub async fn synctex_inverse(
    state: State<'_, AppState>,
    id: String,
    page: f64,
    x: f64,
    y: f64,
) -> CmdResult<InverseLoc> {
    let root = root(&state, &id)?;
    Ok(synctex::synctex_inverse(&root, page, x, y, core_compile::tex_path()).await?)
}

// ---------- export / save-as ----------

/// Ask for a destination path. The dialog runs on its own thread and reports
/// back through a channel, so no command ever blocks the main thread waiting
/// on the user.
async fn ask_save_path(
    app: &AppHandle,
    default_name: &str,
    filter: (&str, &str),
) -> Option<PathBuf> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    let mut builder = app.dialog().file().set_file_name(default_name);
    if let Ok(downloads) = app.path().download_dir() {
        builder = builder.set_directory(downloads);
    }
    builder
        .add_filter(filter.0, &[filter.1])
        .save_file(move |picked| {
            let _ = tx.send(picked);
        });
    rx.await.ok().flatten().and_then(|p| p.into_path().ok())
}

#[tauri::command]
pub async fn export_project(
    app: AppHandle,
    state: State<'_, AppState>,
    id: String,
) -> CmdResult<DialogOutcome> {
    let root = root(&state, &id)?;
    let Some(dest) = ask_save_path(&app, &format!("{id}.zip"), ("ZIP archive", "zip")).await else {
        return Ok(DialogOutcome::canceled());
    };
    zipexport::export_zip(&root, &dest)?;
    let _ = app.opener().reveal_item_in_dir(&dest);
    Ok(DialogOutcome::done())
}

#[tauri::command]
pub async fn save_pdf_as(
    app: AppHandle,
    state: State<'_, AppState>,
    id: String,
) -> CmdResult<DialogOutcome> {
    let root = root(&state, &id)?;
    let src = settings::compiled_pdf_path(&root)?;
    if !src.exists() {
        return Err(CmdError("No compiled PDF yet".into()));
    }
    let Some(dest) = ask_save_path(&app, &format!("{id}.pdf"), ("PDF", "pdf")).await else {
        return Ok(DialogOutcome::canceled());
    };
    std::fs::copy(&src, &dest)?;
    let _ = app.opener().reveal_item_in_dir(&dest);
    Ok(DialogOutcome::done())
}

// ---------- shell plumbing ----------

/// The renderer publishes its whole menu spec whenever a command's title or
/// enabled state changes. Accepted and dropped for now; the native menu is
/// built from it in the next commit.
#[tauri::command]
pub fn menu_sync(spec: Value) {
    let _ = spec;
}

/// The renderer acknowledging that a pending edit has reached disk. See
/// window.rs for the handshake this completes.
#[tauri::command]
pub fn quit_flush_done(state: State<'_, AppState>) {
    if let Some(tx) = state.flush_ack.lock().unwrap().take() {
        let _ = tx.send(());
    }
}
