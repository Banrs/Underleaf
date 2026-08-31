//! The native application menu. Its shape and enabled state come from the
//! renderer's command model (web/src/commands.js), so a menu item can't drift
//! from the shortcut or toolbar button that runs the same command.
//!
//! The renderer republishes its whole spec on every state change — a compile
//! starting, a file opening, a pane toggling. Electron rebuilt the entire
//! NSMenu each time; here the menu is built once and later publishes only
//! push the changed titles, enabled flags, and check marks onto the items
//! already on screen.

use std::collections::HashMap;

use serde::Deserialize;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Manager, Wry};

use crate::window;

const GITHUB_URL: &str = "https://github.com/Banrs/Underleaf";
const SETTINGS_ID: &str = "app.settings";
const QUIT_ID: &str = "app.quit";
const GITHUB_ID: &str = "help.github";
const DEVTOOLS_ID: &str = "help.devtools";

// ---------- the spec the renderer publishes ----------

#[derive(Deserialize)]
pub struct GroupSpec {
    label: String,
    items: Vec<ItemSpec>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ItemSpec {
    /// The literal "-" the renderer uses for a separator. Matched by shape:
    /// this variant is tried first and only accepts a JSON string, so entries
    /// (objects) fall through to the next one.
    Separator(#[allow(dead_code)] String),
    Entry(EntrySpec),
}

#[derive(Deserialize)]
struct EntrySpec {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    accelerator: Option<String>,
    #[serde(default)]
    enabled: Option<bool>,
    #[serde(default)]
    checked: Option<bool>,
}

impl EntrySpec {
    fn enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
}

/// Two spellings Electron accepts that muda does not. `Plus` is the zoom-in
/// key, which is unshifted `=` on the layouts this ships to — the same key the
/// browser-mode matcher in commands.js already accepts.
fn muda_accelerator(accel: &str) -> String {
    match accel.rsplit_once('+') {
        Some((mods, "Return")) => format!("{mods}+Enter"),
        Some((mods, "Plus")) => format!("{mods}+Equal"),
        _ => accel.to_string(),
    }
}

// ---------- built menu ----------

enum Handle {
    Plain(MenuItem<Wry>),
    Check(CheckMenuItem<Wry>),
}

pub struct MenuState {
    /// Group labels and item ids in order — the menu is rebuilt only if this
    /// changes, which the static MENU in commands.js never does.
    shape: Vec<String>,
    items: HashMap<String, Handle>,
}

fn shape_of(spec: &[GroupSpec]) -> Vec<String> {
    let mut shape = Vec::new();
    for group in spec {
        shape.push(format!("@{}", group.label));
        for item in &group.items {
            shape.push(match item {
                ItemSpec::Separator(_) => "-".to_string(),
                ItemSpec::Entry(e) => {
                    e.id.clone()
                        .or_else(|| e.role.as_ref().map(|r| format!("role:{r}")))
                        .unwrap_or_default()
                }
            });
        }
    }
    shape
}

fn predefined(app: &AppHandle, role: &str) -> Option<PredefinedMenuItem<Wry>> {
    match role {
        "cut" => PredefinedMenuItem::cut(app, None).ok(),
        "copy" => PredefinedMenuItem::copy(app, None).ok(),
        "paste" => PredefinedMenuItem::paste(app, None).ok(),
        "selectAll" => PredefinedMenuItem::select_all(app, None).ok(),
        "undo" => PredefinedMenuItem::undo(app, None).ok(),
        "redo" => PredefinedMenuItem::redo(app, None).ok(),
        _ => None,
    }
}

/// Build the menu from a spec and install it, recording the item handles so
/// later publishes can just update them.
fn build(app: &AppHandle, spec: &[GroupSpec]) -> tauri::Result<MenuState> {
    let mut items: HashMap<String, Handle> = HashMap::new();
    let menu = Menu::new(app)?;

    let settings_item = |app: &AppHandle| {
        MenuItem::with_id(app, SETTINGS_ID, "Settings…", true, Some("CmdOrCtrl+,"))
    };
    // Quit is a custom item, not the predefined one: it has to route through
    // the flush handshake so a pending edit reaches disk first.
    let quit_item = |app: &AppHandle| {
        MenuItem::with_id(app, QUIT_ID, "Quit TeXLocal", true, Some("CmdOrCtrl+Q"))
    };

    #[cfg(target_os = "macos")]
    {
        let app_menu = Submenu::with_items(
            app,
            "TeXLocal",
            true,
            &[
                &PredefinedMenuItem::about(app, None, None)?,
                &PredefinedMenuItem::separator(app)?,
                &settings_item(app)?,
                &PredefinedMenuItem::separator(app)?,
                &PredefinedMenuItem::services(app, None)?,
                &PredefinedMenuItem::separator(app)?,
                &PredefinedMenuItem::hide(app, None)?,
                &PredefinedMenuItem::hide_others(app, None)?,
                &PredefinedMenuItem::show_all(app, None)?,
                &PredefinedMenuItem::separator(app)?,
                &quit_item(app)?,
            ],
        )?;
        menu.append(&app_menu)?;
    }

    for group in spec {
        let submenu = Submenu::new(app, &group.label, true)?;
        for item in &group.items {
            match item {
                ItemSpec::Separator(_) => submenu.append(&PredefinedMenuItem::separator(app)?)?,
                ItemSpec::Entry(entry) => {
                    if let Some(role) = &entry.role {
                        if let Some(item) = predefined(app, role) {
                            submenu.append(&item)?;
                        }
                        continue;
                    }
                    let Some(id) = entry.id.clone() else { continue };
                    let label = entry.label.clone().unwrap_or_else(|| id.clone());
                    let accel = entry.accelerator.as_deref().map(muda_accelerator);
                    match entry.checked {
                        Some(checked) => {
                            let item = CheckMenuItem::with_id(
                                app,
                                &id,
                                label,
                                entry.enabled(),
                                checked,
                                accel,
                            )?;
                            submenu.append(&item)?;
                            items.insert(id, Handle::Check(item));
                        }
                        None => {
                            let item = MenuItem::with_id(app, &id, label, entry.enabled(), accel)?;
                            submenu.append(&item)?;
                            items.insert(id, Handle::Plain(item));
                        }
                    }
                }
            }
        }

        // Windows and Linux have no application menu, so File carries Settings
        // and Quit — the same fallback the Electron menu used.
        #[cfg(not(target_os = "macos"))]
        if group.label == "File" {
            submenu.append(&PredefinedMenuItem::separator(app)?)?;
            submenu.append(&settings_item(app)?)?;
            submenu.append(&PredefinedMenuItem::separator(app)?)?;
            submenu.append(&quit_item(app)?)?;
        }

        menu.append(&submenu)?;
    }

    let window_menu = Submenu::with_items(
        app,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(app, None)?,
            &PredefinedMenuItem::maximize(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            #[cfg(target_os = "macos")]
            &PredefinedMenuItem::bring_all_to_front(app, None)?,
            #[cfg(not(target_os = "macos"))]
            &PredefinedMenuItem::close_window(app, None)?,
        ],
    )?;
    menu.append(&window_menu)?;

    let help_menu = Submenu::with_items(
        app,
        "Help",
        true,
        &[
            &MenuItem::with_id(app, GITHUB_ID, "Underleaf on GitHub", true, None::<&str>)?,
            &PredefinedMenuItem::separator(app)?,
            &MenuItem::with_id(
                app,
                DEVTOOLS_ID,
                "Toggle Developer Tools",
                true,
                Some("CmdOrCtrl+Alt+I"),
            )?,
        ],
    )?;
    menu.append(&help_menu)?;

    menu.set_as_app_menu()?;
    Ok(MenuState {
        shape: shape_of(spec),
        items,
    })
}

/// Push a fresh spec onto the menu, building it the first time and updating
/// the existing items every time after.
pub fn sync(app: &AppHandle, spec: Vec<GroupSpec>) -> tauri::Result<()> {
    let state = app.state::<crate::state::AppState>();
    let mut current = state.menu.lock().unwrap();

    let rebuild = current.as_ref().is_none_or(|m| m.shape != shape_of(&spec));
    if rebuild {
        *current = Some(build(app, &spec)?);
        return Ok(());
    }

    let menu = current.as_mut().expect("present after the rebuild check");
    for group in &spec {
        for item in &group.items {
            let ItemSpec::Entry(entry) = item else {
                continue;
            };
            let Some(id) = &entry.id else { continue };
            let Some(handle) = menu.items.get(id) else {
                continue;
            };
            match handle {
                Handle::Plain(plain) => {
                    plain.set_enabled(entry.enabled())?;
                    if let Some(label) = &entry.label {
                        plain.set_text(label)?;
                    }
                }
                Handle::Check(check) => {
                    check.set_enabled(entry.enabled())?;
                    if let Some(label) = &entry.label {
                        check.set_text(label)?;
                    }
                    if let Some(checked) = entry.checked {
                        check.set_checked(checked)?;
                    }
                }
            }
        }
    }
    Ok(())
}

/// Route a menu click. The shell owns the few items that act on the process
/// itself; everything else is a renderer command, delivered by id.
pub fn on_event(app: &AppHandle, id: &str) {
    match id {
        QUIT_ID => window::quit(app),
        GITHUB_ID => {
            use tauri_plugin_opener::OpenerExt;
            let _ = app.opener().open_url(GITHUB_URL, None::<&str>);
        }
        DEVTOOLS_ID => {
            if let Some(w) = app.get_webview_window(window::MAIN_WINDOW) {
                if w.is_devtools_open() {
                    w.close_devtools();
                } else {
                    w.open_devtools();
                }
            }
        }
        _ => {
            use tauri::Emitter;
            let _ = app.emit_to(window::MAIN_WINDOW, "command:run", id);
        }
    }
}

/// A menu with the standard editing items, shown until the renderer publishes
/// its first spec so the usual shortcuts work during startup.
pub fn install_fallback(app: &AppHandle) -> tauri::Result<()> {
    let spec = vec![
        GroupSpec {
            label: "File".into(),
            items: vec![],
        },
        GroupSpec {
            label: "Edit".into(),
            items: ["undo", "redo", "cut", "copy", "paste", "selectAll"]
                .into_iter()
                .map(|role| {
                    ItemSpec::Entry(EntrySpec {
                        id: None,
                        role: Some(role.into()),
                        label: None,
                        accelerator: None,
                        enabled: None,
                        checked: None,
                    })
                })
                .collect(),
        },
    ];
    sync(app, spec)
}

#[cfg(test)]
mod tests {
    use super::muda_accelerator;

    /// Key tokens muda's parser resolves to a real key. Anything else it
    /// silently turns into a literal character that no keypress can match, so
    /// a new accelerator using an unlisted name would bind to nothing.
    fn muda_knows(key: &str) -> bool {
        const NAMED: &[&str] = &[
            "Comma",
            "Period",
            "Slash",
            "Backslash",
            "Equal",
            "Minus",
            "Semicolon",
            "Quote",
            "BracketLeft",
            "BracketRight",
            "Backquote",
            "Enter",
            "Escape",
            "Space",
            "Tab",
            "Backspace",
            "Delete",
            "ArrowUp",
            "ArrowDown",
            "ArrowLeft",
            "ArrowRight",
        ];
        const SYMBOLS: &[&str] = &[",", ".", "/", "\\", "=", "-", ";", "'", "[", "]", "`"];
        (key.len() == 1 && key.chars().all(|c| c.is_ascii_alphanumeric()))
            || SYMBOLS.contains(&key)
            || NAMED.iter().any(|n| n.eq_ignore_ascii_case(key))
            || (key.starts_with('F') && key[1..].parse::<u8>().is_ok())
    }

    fn key_of(accel: &str) -> &str {
        accel.rsplit_once('+').map(|(_, key)| key).unwrap_or(accel)
    }

    #[test]
    fn translates_the_two_tokens_muda_spells_differently() {
        assert_eq!(muda_accelerator("CmdOrCtrl+Return"), "CmdOrCtrl+Enter");
        assert_eq!(muda_accelerator("Ctrl+Shift+Return"), "Ctrl+Shift+Enter");
        assert_eq!(muda_accelerator("CmdOrCtrl+Plus"), "CmdOrCtrl+Equal");
        assert_eq!(
            muda_accelerator("CmdOrCtrl+Alt+Plus"),
            "CmdOrCtrl+Alt+Equal"
        );
        // Everything else is already spelled the way muda reads it.
        assert_eq!(muda_accelerator("CmdOrCtrl+Shift+Z"), "CmdOrCtrl+Shift+Z");
        assert_eq!(muda_accelerator("CmdOrCtrl+,"), "CmdOrCtrl+,");
        assert_eq!(muda_accelerator("CmdOrCtrl+Minus"), "CmdOrCtrl+Minus");
    }

    /// Reads the accelerators the renderer actually declares, so adding one
    /// with a key muda can't parse fails here rather than shipping a menu item
    /// whose shortcut does nothing.
    #[test]
    fn every_declared_accelerator_survives_translation() {
        // The two modules that register commands; commands.js holds the menu
        // shape, the accelerators are declared with the commands themselves.
        const SOURCES: &[&str] = &[
            include_str!("../../web/src/workspace.js"),
            include_str!("../../web/src/home.js"),
        ];
        let mut checked = 0;
        for source in SOURCES {
            for (i, marker) in source.match_indices("accel: '") {
                let rest = &source[i + marker.len()..];
                let Some(accel) = rest.split('\'').next() else {
                    continue;
                };
                // The JS source escapes a literal backslash key as "\\".
                let accel = accel.replace("\\\\", "\\");
                let translated = muda_accelerator(&accel);
                assert!(
                    muda_knows(key_of(&translated)),
                    "accelerator {accel:?} translates to {translated:?}, whose key muda cannot \
                     parse — add a mapping in muda_accelerator",
                );
                checked += 1;
            }
        }
        assert!(
            checked > 20,
            "expected the command model's accelerators, found {checked}"
        );
    }
}
