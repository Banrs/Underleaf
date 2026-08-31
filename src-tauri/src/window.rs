//! Window creation, the navigation lockdown, and the flush-before-exit
//! handshake — the parts of electron/main.mjs's window setup that carry
//! behavior rather than chrome.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tauri::{
    AppHandle, Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent,
};
use tauri_plugin_opener::OpenerExt;

use crate::state::AppState;

pub const MAIN_WINDOW: &str = "main";
const FLUSH_TIMEOUT: Duration = Duration::from_millis(1500);

pub fn create(app: &AppHandle) -> tauri::Result<WebviewWindow> {
    let nav_handle = app.clone();
    #[allow(unused_mut)]
    let mut builder =
        WebviewWindowBuilder::new(app, MAIN_WINDOW, WebviewUrl::App("index.html".into()))
            .title("TeXLocal")
            .inner_size(1440.0, 900.0)
            .min_inner_size(800.0, 500.0)
            // The command surface is trusted because only the app's own UI can
            // reach it, so nothing may navigate this window elsewhere. External
            // links (hyperref URLs opened from the PDF) go to the system browser.
            .on_navigation(move |url| {
                let scheme = url.scheme();
                if scheme == "tauri" || scheme == crate::protocol::SCHEME {
                    return true;
                }
                if url.host_str().is_some_and(|h| h.ends_with(".localhost")) {
                    return true;
                }
                if matches!(scheme, "http" | "https" | "mailto") {
                    let _ = nav_handle.opener().open_url(url.as_str(), None::<&str>);
                }
                false
            });

    // Native liquid-glass on macOS: the window is transparent, vibrancy renders
    // behind it, and the app's own chrome doubles as the title bar with the
    // lights placed in its 52px band. Elsewhere: a normal opaque title bar.
    #[cfg(target_os = "macos")]
    {
        use tauri::utils::config::{WindowEffect, WindowEffectState, WindowEffectsConfig};
        builder = builder
            .transparent(true)
            .title_bar_style(tauri::TitleBarStyle::Overlay)
            .hidden_title(true)
            .traffic_light_position(tauri::LogicalPosition::new(18.0, 19.0))
            .effects(WindowEffectsConfig {
                effects: vec![WindowEffect::Sidebar],
                state: Some(WindowEffectState::FollowsWindowActiveState),
                radius: None,
                color: None,
            });
    }
    #[cfg(not(target_os = "macos"))]
    {
        builder = builder.background_color(tauri::utils::config::Color(0x1e, 0x1e, 0x1e, 0xff));
    }

    let window = builder.build()?;
    install_flush_on_close(app.clone(), &window);
    Ok(window)
}

/// Quitting or closing must not drop an unsaved buffer: give the renderer one
/// chance to write a pending edit, then continue when it acknowledges or after
/// a short timeout so neither exit path can hang. On macOS closing is not
/// quitting, so the window close needs this as much as Quit does.
fn install_flush_on_close(app: AppHandle, window: &WebviewWindow) {
    let flushing = Arc::new(AtomicBool::new(false));
    let label = window.label().to_string();

    window.on_window_event(move |event| {
        let WindowEvent::CloseRequested { api, .. } = event else {
            return;
        };
        // A second click while the first flush is still running must not start
        // another one; the task below always finishes the close.
        if flushing.swap(true, Ordering::SeqCst) {
            api.prevent_close();
            return;
        }
        api.prevent_close();

        let (tx, rx) = tokio::sync::oneshot::channel();
        {
            let state = app.state::<AppState>();
            *state.flush_ack.lock().unwrap() = Some(tx);
        }
        let _ = app.emit_to(label.as_str(), "app:before-quit", ());

        let app = app.clone();
        let label = label.clone();
        tauri::async_runtime::spawn(async move {
            let _ = tokio::time::timeout(FLUSH_TIMEOUT, rx).await;
            app.state::<AppState>().flush_ack.lock().unwrap().take();
            if let Some(window) = app.get_webview_window(&label) {
                // destroy() does not re-fire CloseRequested, so this can't loop.
                let _ = window.destroy();
            }
        });
    });
}

/// Bring the existing window forward — for a second launch, or the macOS dock
/// icon being clicked while no window is open.
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
