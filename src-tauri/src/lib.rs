//! TeXLocal's desktop shell. No HTTP server and no ports: the UI is served
//! from Tauri's app protocol, talks to this process over commands, and reads
//! PDFs and project files through the `texlocal://` scheme.

mod commands;
mod error;
mod protocol;
mod state;
mod window;

use std::path::PathBuf;

use tauri::{Manager, RunEvent};

use state::AppState;

/// Projects live in ~/TeXLocal — visible in the file manager, syncable, and
/// (unlike ~/Documents on macOS) not behind a privacy gate, so the app never
/// hangs waiting on a folder-permission prompt.
fn data_dir(app: &tauri::AppHandle) -> PathBuf {
    if let Some(dir) = std::env::var_os("TEXLOCAL_DATA").filter(|v| !v.is_empty()) {
        return PathBuf::from(dir);
    }
    app.path()
        .home_dir()
        .map(|home| home.join("TeXLocal"))
        .unwrap_or_else(|_| PathBuf::from("TeXLocal"))
}

pub fn run() {
    tauri::Builder::default()
        // Registered first so a second launch reaches the running instance
        // instead of opening a rival window over the same project directory.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            window::focus_or_create(app);
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .register_asynchronous_uri_scheme_protocol(protocol::SCHEME, protocol::handle)
        .invoke_handler(tauri::generate_handler![
            commands::status,
            commands::list_projects,
            commands::create_project,
            commands::rename_project,
            commands::delete_project,
            commands::get_settings,
            commands::set_settings,
            commands::file_tree,
            commands::scan_symbols,
            commands::search_project,
            commands::read_file,
            commands::write_file,
            commands::create_entry,
            commands::rename_entry,
            commands::delete_entry,
            commands::upload_file,
            commands::compile,
            commands::synctex_forward,
            commands::synctex_inverse,
            commands::export_project,
            commands::save_pdf_as,
            commands::quit_flush_done,
        ])
        .setup(|app| {
            let handle = app.handle();
            let dir = data_dir(handle);
            std::fs::create_dir_all(&dir)?;
            app.manage(AppState::new(dir));
            window::create(handle)?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to start TeXLocal")
        .run(|app, event| match event {
            // On macOS closing the window is not quitting: the app stays in the
            // dock and reopens the window when its icon is clicked. A user-driven
            // exit carries no code; Quit calls app.exit() and passes one through.
            #[cfg(target_os = "macos")]
            RunEvent::ExitRequested {
                code: None, api, ..
            } => api.prevent_exit(),
            #[cfg(target_os = "macos")]
            RunEvent::Reopen { .. } => window::focus_or_create(app),
            // Compiles run in their own process groups so a kill reaches the
            // whole latexmk tree, which also means nothing signals them when
            // this process exits unless we do it here.
            RunEvent::Exit => app.state::<AppState>().compile.kill_all(),
            _ => {}
        });
}
