//! The desktop command surface. Every core command goes through
//! `Service::call` by name, as it does for the browser server and the native
//! apps; only what needs the shell — raw upload bodies, notifications,
//! dialogs, menus, the quit handshake — has a command of its own here.

use std::path::PathBuf;

use serde::Serialize;
use serde_json::{json, Value};
use tauri::ipc::{InvokeBody, Request};
use tauri::{AppHandle, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

use texlocal_core::compile::{CompileOverrides, CompileResult};
use texlocal_core::zipexport;

use crate::error::{CmdError, CmdResult};
use crate::state::{AppState, FlushOutcome};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Saved {
    pub saved: Vec<String>,
}

/// Every core command by name: the dispatch table the browser server and the
/// native apps use.
#[tauri::command]
pub async fn call(
    state: State<'_, AppState>,
    command: String,
    args: Option<Value>,
) -> CmdResult<Value> {
    let args = args.unwrap_or_else(|| json!({}));
    Ok(state.service.call(&command, &args).await?)
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
    let replace = request
        .headers()
        .get("x-replace")
        .is_some_and(|v| v == "true");
    let rel = state.service.upload_file(
        &header("x-project")?,
        &header("x-dir")?,
        &header("x-path")?,
        bytes,
        replace,
    )?;
    Ok(Saved { saved: vec![rel] })
}

/// Typed, rather than through `call`, to announce the result.
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
