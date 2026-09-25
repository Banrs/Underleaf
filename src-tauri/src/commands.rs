//! The desktop command surface: thin wrappers over `texlocal_core::service`,
//! which owns every command's path checks and cache invalidation. Only what
//! needs the shell — dialogs, notifications, menus, the quit handshake — is
//! implemented here.

use std::path::PathBuf;

use serde::Serialize;
use serde_json::Value;
use tauri::ipc::{InvokeBody, Request};
use tauri::{AppHandle, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

use texlocal_core::compile::{CompileOverrides, CompileResult, TexStatus};
use texlocal_core::projects::{ProjectInfo, RenameResult, SearchHit, Symbols, TreeNode};
use texlocal_core::service::{DirListing, UploadSpec};
use texlocal_core::settings::Settings;
use texlocal_core::synctex::{ForwardLoc, InverseLoc};
use texlocal_core::zipexport;

use crate::error::{CmdError, CmdResult};
use crate::state::{AppState, FlushOutcome};

#[derive(Serialize)]
pub struct FileText {
    pub text: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Saved {
    pub saved: Vec<String>,
}

// ---------- status ----------

#[tauri::command]
pub async fn status(state: State<'_, AppState>) -> CmdResult<TexStatus> {
    Ok(state.service.status().await)
}

#[tauri::command]
pub async fn set_tex_dir(state: State<'_, AppState>, dir: Option<String>) -> CmdResult<TexStatus> {
    Ok(state.service.set_tex_dir(dir.as_deref()).await?)
}

#[tauri::command]
pub async fn list_dirs(state: State<'_, AppState>, path: Option<String>) -> CmdResult<DirListing> {
    Ok(state.service.list_dirs(path.as_deref())?)
}

// ---------- projects ----------

#[tauri::command]
pub async fn list_projects(state: State<'_, AppState>) -> CmdResult<Vec<ProjectInfo>> {
    Ok(state.service.list_projects()?)
}

#[tauri::command]
pub async fn create_project(
    state: State<'_, AppState>,
    name: String,
    template: Option<String>,
) -> CmdResult<ProjectInfo> {
    Ok(state.service.create_project(&name, template.as_deref())?)
}

#[tauri::command]
pub async fn rename_project(
    state: State<'_, AppState>,
    id: String,
    name: String,
) -> CmdResult<ProjectInfo> {
    Ok(state.service.rename_project(&id, &name)?)
}

#[tauri::command]
pub async fn delete_project(state: State<'_, AppState>, id: String) -> CmdResult<()> {
    Ok(state.service.delete_project(&id)?)
}

// ---------- settings ----------

#[tauri::command]
pub async fn get_settings(state: State<'_, AppState>, id: String) -> CmdResult<Settings> {
    Ok(state.service.get_settings(&id)?)
}

#[tauri::command]
pub async fn set_settings(
    state: State<'_, AppState>,
    id: String,
    patch: Value,
) -> CmdResult<Settings> {
    Ok(state.service.set_settings(&id, &patch)?)
}

// ---------- files ----------

#[tauri::command]
pub async fn file_tree(state: State<'_, AppState>, id: String) -> CmdResult<Vec<TreeNode>> {
    Ok(state.service.file_tree(&id)?)
}

#[tauri::command]
pub async fn scan_symbols(state: State<'_, AppState>, id: String) -> CmdResult<Symbols> {
    Ok(state.service.scan_symbols(&id)?)
}

#[tauri::command]
pub async fn search_project(
    state: State<'_, AppState>,
    id: String,
    query: String,
) -> CmdResult<Vec<SearchHit>> {
    Ok(state.service.search_project(&id, &query)?)
}

#[tauri::command]
pub async fn read_file(
    state: State<'_, AppState>,
    id: String,
    path: String,
) -> CmdResult<FileText> {
    Ok(FileText {
        text: state.service.read_file(&id, &path)?,
    })
}

#[tauri::command]
pub async fn write_file(
    state: State<'_, AppState>,
    id: String,
    path: String,
    text: String,
) -> CmdResult<()> {
    Ok(state.service.write_file(&id, &path, &text)?)
}

#[tauri::command]
pub async fn create_entry(
    state: State<'_, AppState>,
    id: String,
    path: String,
    dir: Option<bool>,
) -> CmdResult<()> {
    Ok(state
        .service
        .create_entry(&id, &path, dir.unwrap_or(false))?)
}

#[tauri::command]
pub async fn rename_entry(
    state: State<'_, AppState>,
    id: String,
    from: String,
    to: String,
) -> CmdResult<RenameResult> {
    Ok(state.service.rename_entry(&id, &from, &to)?)
}

#[tauri::command]
pub async fn delete_entry(state: State<'_, AppState>, id: String, path: String) -> CmdResult<()> {
    Ok(state.service.delete_entry(&id, &path)?)
}

#[tauri::command]
pub async fn validate_uploads(
    state: State<'_, AppState>,
    id: String,
    dir: Option<String>,
    files: Vec<UploadSpec>,
) -> CmdResult<()> {
    Ok(state
        .service
        .validate_uploads(&id, dir.as_deref().unwrap_or_default(), &files)?)
}

/// One file per invoke, body sent raw. The renderer first calls
/// validate_uploads for the whole batch, then reports any unavoidable I/O
/// partial success explicitly.
#[tauri::command]
pub async fn upload_file(state: State<'_, AppState>, request: Request<'_>) -> CmdResult<Saved> {
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
    let rel = state.service.upload_file(
        &header("x-project")?,
        &header("x-dir")?,
        &header("x-path")?,
        bytes,
    )?;
    Ok(Saved { saved: vec![rel] })
}

// ---------- compile / synctex ----------

#[tauri::command]
pub async fn compile(
    app: AppHandle,
    state: State<'_, AppState>,
    id: String,
    options: Option<CompileOverrides>,
) -> CmdResult<CompileResult> {
    let result = state
        .service
        .compile(&id, &options.unwrap_or_default())
        .await?;
    announce(&app, &result);
    Ok(result)
}

fn announce(app: &AppHandle, result: &CompileResult) {
    use tauri_plugin_notification::NotificationExt;

    let focused = app
        .get_webview_window(crate::window::MAIN_WINDOW)
        .and_then(|w| w.is_focused().ok())
        .unwrap_or(true);
    if focused {
        return;
    }
    let body = if result.ok {
        format!("Compiled in {:.1}s", result.duration_ms as f64 / 1000.0)
    } else {
        match result.errors.len() {
            0 => "Compile failed".to_string(),
            1 => "Compile failed — 1 error".to_string(),
            n => format!("Compile failed — {n} errors"),
        }
    };
    let _ = app
        .notification()
        .builder()
        .title("TeXLocal")
        .body(body)
        .show();
}

#[tauri::command]
pub async fn synctex_forward(
    state: State<'_, AppState>,
    id: String,
    file: String,
    line: u32,
) -> CmdResult<ForwardLoc> {
    Ok(state.service.synctex_forward(&id, &file, line).await?)
}

#[tauri::command]
pub async fn synctex_inverse(
    state: State<'_, AppState>,
    id: String,
    page: f64,
    x: f64,
    y: f64,
) -> CmdResult<InverseLoc> {
    Ok(state.service.synctex_inverse(&id, page, x, y).await?)
}

// ---------- export / save-as ----------

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
) -> CmdResult<()> {
    // Resolve before the dialog, so a bad id fails without asking for a path.
    let root = state.service.project_root(&id)?;
    let Some(dest) = ask_save_path(&app, &format!("{id}.zip"), ("ZIP archive", "zip")).await else {
        return Ok(());
    };
    zipexport::export_zip(&root, &dest)?;
    let _ = app.opener().reveal_item_in_dir(&dest);
    Ok(())
}

#[tauri::command]
pub async fn save_pdf_as(app: AppHandle, state: State<'_, AppState>, id: String) -> CmdResult<()> {
    let src = state.service.pdf_path(&id)?;
    if !src.exists() {
        return Err(CmdError("No compiled PDF yet".into()));
    }
    let Some(dest) = ask_save_path(&app, &format!("{id}.pdf"), ("PDF", "pdf")).await else {
        return Ok(());
    };
    std::fs::copy(&src, &dest)?;
    let _ = app.opener().reveal_item_in_dir(&dest);
    Ok(())
}

// ---------- shell plumbing ----------

#[tauri::command]
pub fn menu_sync(app: AppHandle, spec: Vec<crate::menu::GroupSpec>) -> CmdResult<()> {
    Ok(crate::menu::sync(&app, spec)?)
}

#[tauri::command]
pub fn quit_flush_done(state: State<'_, AppState>, ok: bool, error: Option<String>) {
    if let Some(tx) = state.flush_ack.lock().unwrap().take() {
        let _ = tx.send(FlushOutcome { ok, error });
    }
}

#[tauri::command]
pub fn system_accent() -> Option<String> {
    crate::accent::system_accent()
}
