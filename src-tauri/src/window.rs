//! Window creation, navigation lockdown, and the flush-before-exit handshake.

use std::sync::atomic::Ordering;
use std::time::Duration;

use tauri::{
    AppHandle, Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent,
};
use tauri_plugin_opener::OpenerExt;

use crate::state::AppState;

pub const MAIN_WINDOW: &str = "main";
const FLUSH_TIMEOUT: Duration = Duration::from_secs(10);

pub fn create(app: &AppHandle) -> tauri::Result<WebviewWindow> {
    let nav_handle = app.clone();
    #[allow(unused_mut)]
    let mut builder =
        WebviewWindowBuilder::new(app, MAIN_WINDOW, WebviewUrl::App("index.html".into()))
            .title("TeXLocal")
            .inner_size(1440.0, 900.0)
            .min_inner_size(800.0, 500.0)
            // Project content must not be able to create a second privileged
            // webview with window.open or target=_blank. External navigation is
            // deliberately routed through the OS browser below instead.
            .on_new_window(|_, _| tauri::webview::NewWindowResponse::Deny)
            .on_navigation(move |url| {
                let scheme = url.scheme();
                let trusted_http_host = matches!(
                    url.host_str(),
                    Some("tauri.localhost") | Some("texlocal.localhost")
                );
                if scheme == "tauri"
                    || scheme == crate::protocol::SCHEME
                    || (scheme == "http" && trusted_http_host)
                {
                    return true;
                }
                if matches!(scheme, "http" | "https" | "mailto") {
                    let _ = nav_handle.opener().open_url(url.as_str(), None::<&str>);
                }
                false
            });

    #[cfg(target_os = "macos")]
    {
        builder = builder
            .transparent(true)
            .title_bar_style(tauri::TitleBarStyle::Overlay)
            .hidden_title(true)
            .traffic_light_position(tauri::LogicalPosition::new(18.0, 19.0))
            .effects(sidebar_vibrancy());
    }
    #[cfg(not(target_os = "macos"))]
    {
        builder = builder.background_color(tauri::utils::config::Color(0x1e, 0x1e, 0x1e, 0xff));
    }

    let window = builder.build()?;
    install_flush_on_close(app.clone(), &window);
    Ok(window)
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn sidebar_vibrancy() -> tauri::utils::config::WindowEffectsConfig {
    use tauri::utils::config::WindowEffectsConfig;
    use tauri::utils::{WindowEffect, WindowEffectState};
    WindowEffectsConfig {
        effects: vec![WindowEffect::Sidebar],
        state: Some(WindowEffectState::FollowsWindowActiveState),
        radius: None,
        color: None,
    }
}

enum FlushAction {
    Close(String),
    Exit,
}

fn restore_after_aborted_flush(app: &AppHandle, reason: &str) {
    eprintln!("quit/close aborted: {reason}");
    // The renderer makes the document inert before its final flush so no edit
    // can arrive between acknowledgement and destruction. A native timeout or
    // dropped responder must release that lock explicitly.
    let _ = app.emit_to(MAIN_WINDOW, "app:quit-aborted", reason);
    if let Some(window) = app.get_webview_window(MAIN_WINDOW) {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Ask the renderer to persist pending edits. Only an explicit successful
/// acknowledgement performs the requested close/exit; failure, a dropped
/// responder, or timeout leaves the window and process intact.
fn flush_then(app: &AppHandle, action: FlushAction) -> bool {
    let state = app.state::<AppState>();
    if state.flushing.swap(true, Ordering::SeqCst) {
        if matches!(&action, FlushAction::Exit) {
            state.exit_after_flush.store(true, Ordering::SeqCst);
        }
        return false;
    }

    if matches!(&action, FlushAction::Exit) {
        state.exit_after_flush.store(true, Ordering::SeqCst);
    }
    let (tx, rx) = tokio::sync::oneshot::channel();
    *state.flush_ack.lock().unwrap() = Some(tx);
    if let Err(err) = app.emit_to(MAIN_WINDOW, "app:before-quit", ()) {
        state.flush_ack.lock().unwrap().take();
        state.flushing.store(false, Ordering::SeqCst);
        state.exit_after_flush.store(false, Ordering::SeqCst);
        restore_after_aborted_flush(app, &format!("could not request a save: {err}"));
        return false;
    }

    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let result = tokio::time::timeout(FLUSH_TIMEOUT, rx).await;
        let state = app.state::<AppState>();
        state.flush_ack.lock().unwrap().take();
        state.flushing.store(false, Ordering::SeqCst);

        match result {
            Ok(Ok(outcome)) if outcome.ok => {}
            Ok(Ok(outcome)) => {
                state.exit_after_flush.store(false, Ordering::SeqCst);
                restore_after_aborted_flush(
                    &app,
                    outcome.error.as_deref().unwrap_or("the document could not be saved"),
                );
                return;
            }
            Ok(Err(_)) => {
                state.exit_after_flush.store(false, Ordering::SeqCst);
                restore_after_aborted_flush(&app, "the renderer closed before saving");
                return;
            }
            Err(_) => {
                state.exit_after_flush.store(false, Ordering::SeqCst);
                restore_after_aborted_flush(&app, "saving did not finish before the timeout");
                return;
            }
        }

        let exit = state.exit_after_flush.swap(false, Ordering::SeqCst)
            || matches!(&action, FlushAction::Exit);
        if exit {
            app.exit(0);
        } else if let FlushAction::Close(label) = action {
            if let Some(window) = app.get_webview_window(&label) {
                let _ = window.destroy();
            }
        }
    });
    true
}

pub fn quit(app: &AppHandle) {
    if app.get_webview_window(MAIN_WINDOW).is_none() {
        app.exit(0);
        return;
    }
    let _ = flush_then(app, FlushAction::Exit);
}

fn install_flush_on_close(app: AppHandle, window: &WebviewWindow) {
    let label = window.label().to_string();
    window.on_window_event(move |event| {
        let WindowEvent::CloseRequested { api, .. } = event else {
            return;
        };
        api.prevent_close();
        let _ = flush_then(&app, FlushAction::Close(label.clone()));
    });
}

pub fn focus_or_create(app: &AppHandle) {
    match app.get_webview_window(MAIN_WINDOW) {
        Some(window) => {
            let _ = window.unminimize();
            let _ = window.show();
            let _ = window.set_focus();
        }
        None => {
            if let Err(err) = create(app) {
                eprintln!("failed to create window: {err}");
            }
        }
    }
}
