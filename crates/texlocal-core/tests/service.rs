//! The library as the hosts reach it: the service's JSON commands, and the
//! project rules (settings, renames, the symbol scan) that sessions apply.

mod support;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};
use tempfile::TempDir;
use texlocal_core::CoreError;
use texlocal_core::paths::{project_root, rel_to_root, safe_rel_file};
use texlocal_core::projects::{SymbolScan, Symbols, create_file, create_project};
use texlocal_core::projects::{rename_entry, rename_project};
use texlocal_core::service::Service;
use texlocal_core::session::Sessions;
use texlocal_core::settings::{read_settings, write_settings};

/// A library, its service, and the runtime its commands run on.
struct Library {
    dir: TempDir,
    service: Service,
    runtime: tokio::runtime::Runtime,
}

/// A library holding the blank projects `ids`.
fn library(ids: &[&str]) -> Library {
    let (dir, service) = support::library(ids);
    let mut runtime = tokio::runtime::Builder::new_current_thread();
    let runtime = runtime.enable_all().build().unwrap();
    Library {
        dir,
        service,
        runtime,
    }
}

impl Library {
    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn root(&self, id: &str) -> PathBuf {
        self.service.project_root(id).unwrap()
    }

    /// `command`'s answer, its `id` P unless `args` names one.
    fn call(&self, command: &str, mut args: Value) -> Result<Value, CoreError> {
        if args.get("id").is_none() {
            args["id"] = json!("P");
        }
        self.runtime.block_on(self.service.call(command, &args))
    }

    fn ok(&self, command: &str, args: Value) -> Value {
        let answer = self.call(command, args);
        answer.unwrap_or_else(|e| panic!("{command}: {} {}", e.status, e.message))
    }

    fn err(&self, command: &str, args: Value) -> CoreError {
        self.call(command, args).unwrap_err()
    }

    fn write(&self, path: &str, text: &str) -> Value {
        self.ok("write_file", json!({ "path": path, "text": text }))
    }

    /// Each "file:line before[match]after" P's search finds.
    fn search(&self, query: &str) -> Vec<String> {
        let groups = self.ok("search_project", json!({ "query": query }));
        let hits = groups.as_array().unwrap().iter();
        let hits = hits.flat_map(|group| group["hits"].as_array().unwrap().clone());
        let hit = |h: Value| {
            let text = |key: &str| h[key].as_str().unwrap().to_owned();
            let (file, before, matched) = (text("file"), text("before"), text("match"));
            format!("{file}:{} {before}[{matched}]{}", h["line"], text("after"))
        };
        hits.map(hit).collect()
    }

    /// The names of the top of P's tree.
    fn top(&self) -> Vec<String> {
        let tree = self.ok("file_tree", json!({}));
        let names = tree.as_array().unwrap().iter();
        names.map(|n| n["name"].as_str().unwrap().into()).collect()
    }
}

#[track_caller]
fn fails_with<T: std::fmt::Debug>(result: Result<T, CoreError>, text: &str) {
    let message = result.unwrap_err().message;
    assert!(message.contains(text), "{message:?} lacks {text:?}");
}

fn names_in(dir: &Path) -> Vec<String> {
    let entries = fs::read_dir(dir).unwrap();
    let names = entries.map(|e| e.unwrap().file_name().to_string_lossy().into_owned());
    let mut names: Vec<_> = names.collect();
    names.sort();
    names
}

fn zip_names(path: &Path) -> Vec<String> {
    let archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    archive.file_names().map(str::to_owned).collect()
}

fn scan(root: &Path) -> Symbols {
    SymbolScan::default().scan(root).unwrap()
}

#[test]
fn a_new_project_takes_the_first_free_name_its_template_and_its_engine() {
    let lib = library(&[]);
    let free = |name: Value| lib.ok("free_project_name", json!({ "name": name }))["name"].clone();
    assert_eq!(free(Value::Null), "Untitled");
    for want in ["Untitled", "Untitled 2", "Untitled 3"] {
        let made = lib.ok("create_project", json!({ "name": "Untitled" }));
        assert_eq!(made["id"], want);
    }
    // A gap is filled first, and a name asked for is numbered the same way.
    fs::remove_dir_all(lib.path().join("Untitled 2")).unwrap();
    assert_eq!(free(Value::Null), "Untitled 2");
    let folds = cfg!(any(target_os = "macos", windows));
    let want = if folds { "untitled 2" } else { "untitled" };
    assert_eq!(free(json!("untitled")), want);
    let made = lib.ok("create_project", json!({ "name": "Untitled 3" }));
    assert_eq!(made["id"], "Untitled 3 2");

    // Names the path rules refuse are refused, not numbered.
    let hidden = lib.err("free_project_name", json!({ "name": ".hidden" }));
    assert_eq!(hidden.status, 400);
    for name in [json!(null), json!(".hidden"), json!("   ")] {
        let err = lib.err("create_project", json!({ "name": name }));
        assert_eq!(err.status, 400, "{name}");
    }

    let args = json!({ "name": "  Thesis  ", "template": "report" });
    let mut made = lib.ok("create_project", args);
    let mtime = made.as_object_mut().unwrap().remove("mtime");
    assert!(mtime.unwrap().is_u64());
    let want = json!({ "id": "Thesis", "name": "Thesis", "mainFile": "main.tex" });
    assert_eq!(made, want);
    let root = lib.root("Thesis");
    let names = [".texlocal.json", "main.tex", "references.bib"];
    assert_eq!(names_in(&root), names);
    let main = fs::read_to_string(root.join("main.tex")).unwrap();
    assert!(main.contains("{report}"));

    // Made with its engine, or not at all.
    let args = json!({ "name": "Xe", "template": "blank", "engine": "xelatex" });
    let id = lib.ok("create_project", args)["id"].clone();
    let settings = lib.ok("get_settings", json!({ "id": id }));
    assert_eq!(settings["engine"], "xelatex");
    let unknown = json!({ "name": "Odd", "engine": "troff" });
    assert_eq!(lib.err("create_project", unknown).status, 400);
    assert!(!lib.path().join("Odd").exists());

    // Never on an existing entry, even a dangling link.
    #[cfg(unix)]
    {
        let link = lib.path().join("linked");
        std::os::unix::fs::symlink(lib.path().join("gone"), link).unwrap();
        let made = lib.ok("create_project", json!({ "name": "linked" }));
        assert_eq!(made["id"], "linked 2");
        assert!(!lib.path().join("gone").exists());
    }
}

/// `before_move` runs once the rename is sure to go ahead: a project made
/// then gets another name, not the one the rename is taking.
#[test]
fn a_project_rename_claims_its_name_only_once_it_goes_ahead() {
    let lib = library(&["X"]);
    let data = lib.path();
    fs::write(data.join("X/main.tex"), "the user's").unwrap();
    let mut made = None;
    let renamed = rename_project(data, "X", "R", |_| {
        made = Some(create_project(data, "R", "blank")?.name);
        Ok(())
    });
    assert_eq!(renamed.unwrap().name, "R");
    assert_eq!(made.as_deref(), Some("R 2"));
    let text = fs::read_to_string(data.join("R/main.tex")).unwrap();
    assert_eq!(text, "the user's");

    let stopped = rename_project(data, "R", "S", |_| Err(CoreError::conflict("no")));
    assert_eq!(stopped.unwrap_err().status, 409);
    assert_eq!(names_in(data), ["R", "R 2"]);
    // In case only, which case-insensitive volumes take too; onto another, never.
    rename_project(data, "R", "r", |_| Ok(())).unwrap();
    let taken = rename_project(data, "R 2", "r", |_| panic!("moved"));
    assert_eq!(taken.unwrap_err().status, 409);
    assert_eq!(names_in(data), ["R 2", "r"]);
}

#[test]
fn files_are_written_read_made_and_located_through_the_commands() {
    let lib = library(&["P"]);
    lib.write("sec/a.tex", "hello");
    let read = lib.ok("read_file", json!({ "path": "sec/a.tex" }));
    assert_eq!(read, json!({ "text": "hello" }));
    // The Mac app knows its own save's change event by this stamp.
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let stamp = lib.write("main.tex", "saved");
        let meta = fs::metadata(lib.root("P").join("main.tex")).unwrap();
        let (inode, s, ns) = (meta.ino(), meta.mtime(), meta.mtime_nsec());
        let want = json!({ "inode": inode, "size": 5, "seconds": s, "nanoseconds": ns });
        assert_eq!(stamp, want);
    }
    // A write without its text is refused, never taken as an empty file.
    let null = json!({ "path": "main.tex", "text": null });
    for args in [json!({ "path": "main.tex" }), null] {
        let err = lib.err("write_file", args);
        let want = "Invalid argument `text`: invalid type: null, expected a string";
        assert_eq!((err.status, err.message.as_str()), (400, want));
    }
    assert!(fs::metadata(lib.root("P").join("main.tex")).unwrap().len() > 0);

    // A free name is numbered past those taken; a plain create refuses one.
    for want in ["untitled.tex", "untitled 2.tex"] {
        let free = json!({ "path": "untitled.tex", "free": true });
        let made = lib.ok("create_entry", free);
        assert_eq!(made, json!({ "path": want }));
    }
    let taken = lib.err("create_entry", json!({ "path": "untitled.tex" }));
    assert_eq!(taken.status, 409);
    let made = lib.ok("create_entry", json!({ "path": "figs", "dir": true }));
    assert_eq!(made, json!({ "path": "figs" }));
    assert!(lib.root("P").join("figs").is_dir());

    let path = lib.path().join("P/sec/new.tex");
    let located = lib.ok("locate", json!({ "path": path }));
    assert_eq!(located, json!({ "id": "P", "path": "sec/new.tex" }));
    let outside = lib.ok("locate", json!({ "path": lib.path().parent().unwrap() }));
    assert_eq!(outside, Value::Null);

    let root = lib.root("P");
    assert_eq!(lib.ok("project_root", json!({})), json!(root));
    let pdf = root.join("build").join("main.pdf");
    assert_eq!(lib.ok("pdf_path", json!({})), json!(pdf));
    assert_eq!(lib.ok("kill_all", json!({})), Value::Null);
    assert_eq!(lib.ok("stop_compile", json!({})), false);
}

#[test]
fn unknown_commands_and_bad_arguments_are_refused() {
    let lib = library(&["P"]);
    // Raw bytes go through methods, not commands.
    for command in "no_such_command upload_file export_project save_pdf_as".split(' ') {
        assert_eq!(lib.err(command, json!({})).status, 404, "{command}");
    }
    let live = json!({ "file": "a.tex", "line": 1, "live": true });
    for (command, args) in [
        ("read_file", json!({})),
        ("search_project", json!({ "query": 3 })),
        ("synctex_forward", json!({ "file": "a.tex", "line": "x" })),
        ("synctex_forward", live),
    ] {
        assert_eq!(lib.err(command, args).status, 400, "{command}");
    }
}

/// Every path a command takes is held to the project's rules: no way out of
/// it, through `..` or a link, and none to the settings file or into the top
/// `build` folder, the compiled PDF's, in any case.
#[test]
fn paths_are_held_to_the_project_s_rules() {
    let lib = library(&["P"]);
    let root = lib.root("P");
    create_file(&root, "chapters/intro.tex", false).unwrap();
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.pdf"), "pdf").unwrap();
    // Each a command and a path, and what it is refused with, or "".
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut cases = vec![
        ("read ../x", "Path escapes project"),
        ("read a/../../b", "Path escapes project"),
        ("read .", "Path escapes project"),
        ("read /x", "Path escapes project"),
        ("read ", "Missing path"),
        ("read .TEXLOCAL.JSON", "Reserved file"),
        ("write .texlocal.json", "Reserved file"),
        ("write .TexLocal.Json", "Reserved file"),
        ("write ./chapters/../.texlocal.JSON", "Reserved file"),
        ("write sub/.texlocal.json", ""),
        ("read build/main.pdf", ""),
        ("write BUILD/x.tex", "compiled PDF"),
        ("make build", "compiled PDF"),
        ("make figs/build", ""),
        ("write -draft.tex", ""),
    ];
    // A link inside the project is held to its target's rules (#26).
    #[cfg(unix)]
    let _outside = {
        use std::os::unix::fs::symlink;
        let outside = tempfile::tempdir().unwrap();
        fs::write(outside.path().join("secret.tex"), "secret").unwrap();
        let links = [
            (outside.path(), "outside"),
            (Path::new(".texlocal.json"), "alias.json"),
            (Path::new("."), "here"),
            (Path::new("build"), "output"),
            (Path::new("main.tex"), "link.tex"),
        ];
        for (target, name) in links {
            symlink(target, root.join(name)).unwrap();
        }
        cases.extend([
            ("read outside/secret.tex", "Path escapes project"),
            ("write outside/new/sub/file.tex", "Path escapes project"),
            ("read alias.json", "Reserved file"),
            ("write here/.texlocal.json", "Reserved file"),
            ("write output/main.pdf", "compiled PDF"),
            ("write here/build/x.tex", "compiled PDF"),
            ("read output/main.pdf", ""),
            ("write link.tex", ""),
            ("write here/notes.tex", ""),
        ]);
        let escape = safe_rel_file(&root, "outside/secret.tex");
        fails_with(escape, "Path escapes project");
        outside
    };
    for (case, refused) in cases {
        let (how, path) = case.split_once(' ').unwrap();
        let command = match how {
            "read" => "read_file",
            "write" => "write_file",
            _ => "create_entry",
        };
        let args = json!({ "path": path, "text": "x", "dir": how == "make" });
        let answer = lib.call(command, args);
        let message = answer.err().map(|err| err.message).unwrap_or_default();
        let as_expected = message.contains(refused) && message.is_empty() == refused.is_empty();
        assert!(as_expected, "{case}: {message:?}");
    }
    // A folder made elsewhere in another case is still hidden as output.
    fs::create_dir(root.join("BUILD")).ok();
    assert!(!lib.top().iter().any(|n| n.eq_ignore_ascii_case("build")));

    // A project is one folder of the library, and names it however spelt.
    for id in ["../etc", "P/chapters"] {
        let err = lib.err("read_file", json!({ "id": id, "path": "main.tex" }));
        assert_eq!((err.status, err.message.as_str()), (400, "Bad project id"));
    }
    assert_eq!(project_root(lib.path(), "./P/").unwrap(), root);
    let key = safe_rel_file(&root, "./chapters/../chapters//intro.tex").unwrap();
    assert_eq!(key, "chapters/intro.tex");
    // A file as tool output names it.
    let at = |path: &str| rel_to_root(Path::new("/data/P"), Path::new(path));
    let inside = at("/data/P/./ch/../ch/intro.tex");
    assert_eq!(inside.as_deref(), Some("ch/intro.tex"));
    for outside in ["/data/P", "/data/P/../Q/a.tex", "/data/PQ/a.tex"] {
        assert_eq!(at(outside), None, "{outside}");
    }
}

#[test]
fn a_settings_patch_changes_only_its_keys_or_nothing() {
    let lib = library(&["P"]);
    let root = lib.root("P");
    let file = root.join(".texlocal.json");
    let saved = r#"{ "engine": "xelatex", "stopOnFirstError": 3, "custom": "kept" }"#;
    fs::write(&file, saved).unwrap();
    let written = write_settings(&root, &json!({ "shellEscape": true, "unknown": 1 }));
    // The file's engine stays, its mistyped flag reads as the default, and
    // its unknown key survives.
    let expected = json!({
        "mainFile": "main.tex", "engine": "xelatex", "shellEscape": true, "stopOnFirstError": false
    });
    assert_eq!(json!(written.unwrap()), expected);
    assert_eq!(lib.ok("get_settings", json!({})), expected);
    let raw: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    assert_eq!(raw["custom"], "kept");

    let before = fs::read(&file).unwrap();
    // Each the error and the patch.
    for case in [
        r#"Unknown engine|{ "engine": "word", "shellEscape": false }"#,
        r#"expected a boolean|{ "shellEscape": "false" }"#,
        r#"Path segments cannot start|{ "mainFile": "-interaction.tex" }"#,
        r#"Path escapes project|{ "mainFile": "../outside.tex" }"#,
        "Invalid settings|[1]",
    ] {
        let (why, bad) = case.split_once('|').unwrap();
        let bad = serde_json::from_str(bad).unwrap();
        fails_with(write_settings(&root, &bad), why);
    }
    assert_eq!(fs::read(&file).unwrap(), before);

    // The compiled PDF is named after a nested main file.
    create_file(&root, "chapters/paper.tex", false).unwrap();
    write_settings(&root, &json!({ "mainFile": "chapters/paper.tex" })).unwrap();
    let pdf = lib.ok("pdf_path", json!({}));
    assert_eq!(pdf, json!(root.join("build").join("paper.pdf")));
    let listed = lib.ok("list_projects", json!({}));
    assert_eq!(listed[0]["mainFile"], "chapters/paper.tex");
}

#[test]
fn a_rename_takes_the_main_file_along_when_it_holds_it() {
    let lib = library(&["P"]);
    let root = lib.root("P");
    let main = |main: &str| write_settings(&root, &json!({ "mainFile": main })).unwrap();
    let rename = |from, to| rename_entry(&root, from, to);
    create_file(&root, "chapters/main.tex", false).unwrap();
    create_file(&root, "chapters2/other.tex", false).unwrap();
    main("chapters/main.tex");
    let moved = rename("chapters", "content").unwrap();
    assert_eq!(moved.main_file, "content/main.tex");
    assert_eq!(read_settings(&root).main_file, "content/main.tex");
    // Not a folder that only shares the start of its name.
    create_file(&root, "chapters/x.tex", false).unwrap();
    main("chapters2/other.tex");
    rename("chapters", "moved").unwrap();
    assert_eq!(read_settings(&root).main_file, "chapters2/other.tex");
    // Nothing moves into itself.
    assert_eq!(rename("moved", "moved/old/moved").unwrap_err().status, 400);
    assert_eq!(names_in(&root.join("moved")), ["x.tex"]);
    // Only the main file, which reaches latexmk's command line, may not
    // start with a "-".
    create_file(&root, "-draft.tex", false).unwrap();
    let moved = rename("-draft.tex", "-notes/-draft.tex").unwrap();
    assert_eq!(moved.to, "-notes/-draft.tex");
    // A rename in case only works on volumes that ignore case too; another
    // entry in the way is a conflict.
    main("main.tex");
    create_file(&root, "Figures/plot.tex", false).unwrap();
    let moved = rename("main.tex", "Main.tex").unwrap();
    assert_eq!(moved.main_file, "Main.tex");
    rename("Figures", "figures").unwrap();
    create_file(&root, "other.tex", false).unwrap();
    assert_eq!(rename("other.tex", "Main.tex").unwrap_err().status, 409);
    fails_with(rename("figures", "Build"), "compiled PDF");
    let names = "-notes .texlocal.json Main.tex chapters2 content figures moved other.tex";
    assert_eq!(names_in(&root).join(" "), names);
}

#[test]
fn a_rename_whose_settings_cannot_be_written_is_undone() {
    let lib = library(&["P"]);
    let root = lib.root("P");
    fs::rename(root.join(".texlocal.json"), root.join("settings.backup")).unwrap();
    fs::create_dir(root.join(".texlocal.json")).unwrap();
    let err = rename_entry(&root, "main.tex", "paper.tex").unwrap_err();
    assert_eq!(err.status, 500);
    assert!(root.join("main.tex").is_file() && !root.join("paper.tex").exists());
}

#[test]
fn interface_state_is_kept_and_follows_a_rename_with_the_main_file() {
    let lib = library(&["P"]);
    create_file(&lib.root("P"), "ch/a.tex", false).unwrap();
    let patch = json!({ "expandedFolders": ["ch"], "foldedHeadings": ["ch/a.tex\t2:A#1"] });
    assert_eq!(lib.ok("set_ui_state", json!({ "patch": patch })), patch);

    let (service, runtime) = (lib.service, lib.runtime);
    runtime.block_on(async {
        let sessions = Sessions::new(Arc::new(service));
        let ask = async |command: &str, mut args: Value| {
            args["session"] = json!(1);
            let answer = sessions.call(command, &args).await;
            answer.unwrap_or_else(|e| panic!("{command}: {} {}", e.status, e.message))
        };
        let opened = ask("session_open", json!({ "id": "P" })).await;
        assert_eq!(opened["ui"], patch);
        let main = json!({ "patch": { "mainFile": "ch/a.tex" } });
        ask("session_set_settings", main).await;
        let renamed = ask("session_rename", json!({ "from": "ch", "to": "chapters" })).await;
        assert_eq!(renamed["mainFile"], "chapters/a.tex");
        let folds = json!(["chapters/a.tex\t2:A#1"]);
        let moved = json!({ "expandedFolders": ["chapters"], "foldedHeadings": folds });
        assert_eq!(renamed["ui"], moved);
        ask("session_close", json!({})).await;
    });
}

#[test]
fn search_folds_case_and_places_its_match_in_utf16_units_of_the_line() {
    let lib = library(&["P"]);
    for (file, text) in [
        ("ascii.tex", "One\nThe THEOREM holds\n"),
        ("accents.tex", "L'ÉCOLE Normale\nStraße\n"),
        // An image, though SVG is text: its hits would open as a picture.
        ("figure.svg", "<text>theorem</text>\n"),
        ("mixed.tex", "Café\nsee Lemma 3\n"),
        ("wide.tex", "Çà İstanbul, GRÖSSE und Größe\n"),
        ("kelvin.tex", "measured 5 \u{212A} today\n"),
        ("place.tex", "\u{1F600} see a\u{1D538}b, brown, brown\n"),
        ("shrink.tex", "İ \u{212A} \u{1F600} GRÖẞE und\n"),
    ] {
        fs::write(lib.root("P").join(file), text).unwrap();
    }
    let shrink = "shrink.tex:1 İ \u{212A} \u{1F600} [GRÖẞE] und";
    let wide = "wide.tex:1 Çà İstanbul, GRÖSSE und [Größe]";
    for (query, hits) in [
        ("theorem", &["ascii.tex:2 The [THEOREM] holds"][..]),
        ("école", &["accents.tex:1 L'[ÉCOLE] Normale"]),
        ("lemma", &["mixed.tex:2 see [Lemma] 3"]),
        // After characters of several bytes, and one whose lowercase is two
        // characters, the snippet still cuts at the match.
        ("größe", &[shrink, wide]),
        // U+0130 and the Kelvin sign both lowercase into ASCII.
        ("istanbul", &["wide.tex:1 Çà [İstanbul], GRÖSSE und Größe"]),
        ("5 k", &["kelvin.tex:1 measured [5 \u{212A}] today"]),
        ("zzz", &[]),
    ] {
        assert_eq!(lib.search(query), hits, "{query}");
    }
    // A line's first match, in the units an editor selects.
    for (query, column, length) in [("brown", 13, 5), ("a\u{1D538}b", 7, 4), ("gröẞe", 7, 5)] {
        let groups = lib.ok("search_project", json!({ "query": query }));
        let hit = &groups[0]["hits"][0];
        let place = (hit["column"].as_u64(), hit["length"].as_u64());
        assert_eq!(place, (Some(column), Some(length)), "{query}");
    }
}

/// Only the project's own top-level build/ is compile output. A `build` deeper
/// is the author's: listed, archived, searched and scanned.
#[test]
fn the_scans_read_every_file_but_the_build_s_and_the_unreadable() {
    let lib = library(&["P"]);
    let root = lib.root("P");
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.tex"), "needle \\label{gen:one}\n").unwrap();
    create_file(&root, "chapters/build/notes.tex", false).unwrap();
    let notes = "a needle and \\label{deep:one}\n";
    fs::write(root.join("chapters/build/notes.tex"), notes).unwrap();
    let found = "chapters/build/notes.tex:1 a [needle] and \\label{deep:one}";
    assert_eq!(lib.search("needle"), [found]);
    assert_eq!(scan(&root).labels, ["deep:one"]);

    // An unreadable folder or file is left out, failing nothing.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let lock = |path: &str, mode| {
            fs::set_permissions(root.join(path), fs::Permissions::from_mode(mode)).unwrap();
        };
        create_file(&root, "locked/inside.tex", false).unwrap();
        fs::write(root.join("secret.tex"), "needle \\label{secret}").unwrap();
        lock("locked", 0o000);
        lock("secret.tex", 0o000);
        // As root, permissions lock nothing.
        if fs::read_dir(root.join("locked")).is_err() {
            let tree = lib.ok("file_tree", json!({}));
            let (hits, labels) = (lib.search("needle"), scan(&root).labels);
            lock("locked", 0o755);
            let nodes = tree.as_array().unwrap();
            let locked = nodes.iter().find(|n| n["name"] == "locked");
            assert_eq!(locked.unwrap()["children"], json!([]));
            assert_eq!(
                (hits, labels),
                (vec![found.into()], vec!["deep:one".into()])
            );
        }
        lock("locked", 0o755);
    }
}

#[test]
fn the_symbol_scan_reads_labels_and_keys_in_file_order_whatever_the_encoding() {
    let lib = library(&["P"]);
    let write = |file: &str, text: &[u8]| fs::write(lib.root("P").join(file), text).unwrap();
    // Plenty of .bib and .tex files are still Latin-1: ü, 0xFC, is no UTF-8,
    // and a pattern run over the raw bytes would drop its entry whole.
    let latin1 = |text: &str| text.chars().map(|c| c as u8).collect::<Vec<_>>();
    let bib = latin1("@article{müller2020,\n  title={x}\n}\n@article{ok2021,}\n");
    write("refs.bib", &bib);
    write("ch.tex", &latin1("\\label{fig:müller}\n\\label{fig:ok}\n"));
    // Non-breaking spaces, which reference managers and PDF copy-paste emit,
    // are no part of a key, nor stop an entry.
    let pasted = "@article{Smith2020\u{A0},\n}\n@article\u{A0}{Jones2021,\n}\n";
    write("pasted.bib", pasted.as_bytes());
    // Comments hide symbols, but not after an escaped percent; files go in
    // name order, and a repeated symbol keeps its first place.
    let main = "\\label{kept} % \\label{old}\n% \\bibitem{gone}\n50\\% \\label{after-percent}\n\
        \\label{fig:} \\begin{thebibliography}{9}\n\\bibitem[K]{knuth} K.\n\\bibitem {lamport} L.\n";
    write("main.tex", main.as_bytes());
    let again = b"\\label{last}\\label{fig:ok}\\bibitem{knuth}\\label{kept}";
    write("z.tex", again);

    let Symbols { citations, labels } = scan(&lib.root("P"));
    let names = |names: &[String]| names.join(" ").replace('\u{FFFD}', "?");
    let keys = "knuth lamport Smith2020 Jones2021 m?ller2020 ok2021";
    assert_eq!(names(&citations), keys);
    assert_eq!(names(&labels), "fig:m?ller fig:ok kept after-percent last");
}

#[test]
fn the_tree_lists_folders_first_then_names_in_any_case_and_dates_the_project() {
    let lib = library(&["P"]);
    let root = lib.root("P");
    for file in ["c.tex", "B.tex", "Zeta/z.tex", "beta/y.tex", ".hidden.tex"] {
        create_file(&root, file, false).unwrap();
    }
    assert_eq!(lib.top(), ["beta", "Zeta", "B.tex", "c.tex", "main.tex"]);
    let tree = lib.ok("file_tree", json!({}));
    let zeta = json!({ "type": "dir", "name": "Zeta", "path": "Zeta", "children": [
        { "type": "file", "name": "z.tex", "path": "Zeta/z.tex", "kind": "tex" }
    ] });
    assert_eq!(tree[1], zeta);

    // By its newest file: a file saved in place leaves its folder's date alone.
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
    let main = fs::File::options().write(true).open(root.join("main.tex"));
    main.unwrap().set_modified(later).unwrap();
    let since = later.duration_since(std::time::UNIX_EPOCH).unwrap();
    let listed = lib.ok("list_projects", json!({}));
    assert_eq!(listed[0]["mtime"], since.as_millis() as u64);
}

#[test]
fn the_zip_holds_the_project_as_dated_without_build_settings_litter_or_itself() {
    let lib = library(&["P"]);
    let root = lib.root("P");
    for (file, text) in [
        ("chapters/intro.tex", "x"),
        ("sub/.texlocal.json", "{}"),
        ("build/main.pdf", "pdf"),
        (".latexmkrc", "$pdf_mode = 1;"),
        (".DS_Store", "x"),
        ("chapters/.DS_Store", "x"),
        ("project.zip", "an old incomplete archive"),
    ] {
        fs::create_dir_all(root.join(file).parent().unwrap()).unwrap();
        fs::write(root.join(file), text).unwrap();
    }
    // Into the project, over an old file there.
    let dest = root.join("project.zip");
    lib.ok("export_zip", json!({ "dest": dest }));
    // A nested settings file is the author's.
    let names = ".latexmkrc chapters/ chapters/intro.tex main.tex sub/ sub/.texlocal.json";
    assert_eq!(zip_names(&dest).join(" "), names);
    // To the minute, as ZIP dates in steps of two seconds.
    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let main = archive.by_name("main.tex").unwrap();
    let dated = main.last_modified().unwrap();
    let modified = fs::metadata(root.join("main.tex")).unwrap().modified();
    let local = chrono::DateTime::<chrono::Local>::from(modified.unwrap());
    let minute = local.format("%Y-%m-%d %H:%M").to_string();
    assert_eq!(dated.to_string()[..16], minute);

    // What the app makes gets the mode any new file gets.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = |file: &str| fs::metadata(root.join(file)).unwrap().permissions().mode();
        lib.ok("create_entry", json!({ "path": "notes.tex" }));
        let made = ["notes.tex", ".texlocal.json", "project.zip"].map(mode);
        assert_eq!(made, [mode("main.tex"); 3]);
    }
}

/// A link to a file inside is content. One to a folder, outside, broken or in
/// a loop is not, and fails neither the tree, the scans nor the ZIP, however
/// the project's folder is reached.
#[cfg(unix)]
#[test]
fn only_links_to_files_inside_the_project_are_followed_however_it_is_reached() {
    use std::os::unix::fs::symlink;
    let lib = library(&["P"]);
    let root = lib.root("P");
    let outside = tempfile::tempdir().unwrap();
    let secret = outside.path().join("secret.tex");
    fs::write(&secret, "needle\n\\label{outside-secret}\n").unwrap();
    fs::write(root.join("source.txt"), "needle \\label{linked}").unwrap();
    create_file(&root, "figures/a.txt", false).unwrap();
    for (target, name) in [
        (root.join("source.txt"), "linked.tex"),
        (secret, "external.tex"),
        (root.join("figures"), "linked-dir"),
        (root.clone(), "loop"),
        (root.join("gone.tex"), "broken.tex"),
        (root.join("b.tex"), "a.tex"),
        (root.join("a.tex"), "b.tex"),
    ] {
        symlink(target, root.join(name)).unwrap();
    }
    let alias = lib.path().join("alias");
    symlink(&root, &alias).unwrap();

    for base in [&root, &alias] {
        let tree = texlocal_core::projects::file_tree(base).unwrap();
        let top: Vec<_> = tree.iter().map(|n| n.path.as_str()).collect();
        assert_eq!(top, ["figures", "linked.tex", "main.tex", "source.txt"]);
        assert_eq!(scan(base).labels, ["linked"]);
    }
    let hits = ["linked.tex", "source.txt"].map(|f| format!("{f}:1 [needle] \\label{{linked}}"));
    assert_eq!(lib.search("needle"), hits);
    // The destination spelled through a link into the project, as when a Save
    // panel hands back /private/var for a data folder under /var: a lexical
    // comparison would archive the ZIP's own half-written temporary file.
    lib.ok("export_zip", json!({ "dest": alias.join("out.zip") }));
    let dest = root.join("out.zip");
    let names = "figures/ figures/a.txt linked.tex main.tex source.txt";
    assert_eq!(zip_names(&dest).join(" "), names);
    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let mut body = String::new();
    let mut linked = archive.by_name("linked.tex").unwrap();
    std::io::Read::read_to_string(&mut linked, &mut body).unwrap();
    assert_eq!(body, "needle \\label{linked}");
}

#[test]
fn synctex_match_finds_the_word_at_a_source_caret_among_the_pages() {
    let lib = library(&["P"]);
    lib.write("main.tex", "alpha beta gamma\n");
    let page = json!({ "page": 2, "text": "alpha beta gamma", "near": [[0, 16]] });
    let args = json!({ "file": "main.tex", "line": 1, "column": 8, "pages": [page] });
    let hit = lib.ok("synctex_match", args);
    assert_eq!(hit, json!({ "page": 2, "start": 6, "end": 10 }));
    let beyond = json!({ "file": "main.tex", "line": 9, "column": 0, "pages": [] });
    assert_eq!(lib.ok("synctex_match", beyond), Value::Null);
}

/// The TeX folder is one holding latexmk, or a TeX root above one; it's kept
/// in the library for every host, and its programs are probed afresh.
#[test]
fn the_tex_folder_chosen_is_checked_kept_for_every_host_and_probed_afresh() {
    let lib = library(&["P"]);
    let first = lib.ok("status", json!({}));
    assert_eq!(first["texDir"], Value::Null);
    assert!(first.as_object().unwrap().contains_key("found"));
    let tex = TempDir::new().unwrap();
    for dir in [json!(tex.path()), json!("relative/bin")] {
        let err = lib.err("set_tex_dir", json!({ "dir": dir }));
        assert!(err.status == 400 && err.message.contains("doesn't contain latexmk"));
    }
    assert_eq!(lib.service.tex_dir(), None);

    let bin = tex.path().join("bin").join("universal-darwin");
    support::echoing(&bin, "latexmk", "Latexmk, stub 1.0");
    // A TeX root resolves to its bin folder.
    let chosen = lib.ok("set_tex_dir", json!({ "dir": tex.path() }));
    for key in ["texDir", "found"] {
        assert_eq!(chosen[key], json!(bin), "{key}");
    }
    assert_eq!(chosen["available"], true);
    assert_eq!(chosen["version"], "Latexmk, stub 1.0");
    assert_eq!(chosen["latexmkVersion"], Value::Null, "no version number");
    assert_eq!(lib.ok("status", json!({})), chosen);
    // An update in the same folder shows without another choice.
    support::echoing(&bin, "latexmk", "Latexmk, John Collins, Version 4.86a");
    assert_eq!(lib.ok("status", json!({}))["latexmkVersion"], "4.86a");

    // Another host on the library sees it; the settings file is no project.
    let other = Service::new(lib.path().to_path_buf());
    assert_eq!(other.tex_dir().as_ref(), Some(&bin));
    let saved = fs::read(lib.path().join(".texlocal-app.json")).unwrap();
    let saved: Value = serde_json::from_slice(&saved).unwrap();
    assert_eq!(saved, json!({ "texDir": bin }));
    let listed = lib.ok("list_projects", json!({}));
    assert_eq!(listed.as_array().unwrap().len(), 1);

    // TeXpresso's folder must hold the program, and is kept beside TeX's.
    let folder = TempDir::new().unwrap();
    let dir = json!({ "dir": folder.path() });
    assert_eq!(lib.err("set_texpresso_dir", dir.clone()).status, 400);
    assert!(lib.ok("status", json!({}))["texpressoDir"].is_null());
    let exe = support::echoing(folder.path(), "texpresso", "");
    let status = lib.ok("set_texpresso_dir", dir);
    assert_eq!(status["texpressoDir"], json!(folder.path()));
    assert_eq!(status["texDir"], json!(bin));
    if std::env::var_os("TEXLOCAL_TEXPRESSO").is_none() {
        let exe = dunce::canonicalize(&exe).unwrap();
        assert_eq!(status["texpresso"], json!(exe));
    }
    let cleared = lib.ok("set_texpresso_dir", json!({ "dir": null }));
    assert_eq!(cleared["texpressoDir"], Value::Null);
    assert_eq!(cleared["texDir"], json!(bin));

    // None or blank goes back to finding TeX by itself.
    for dir in [json!(null), json!("  ")] {
        lib.ok("set_tex_dir", json!({ "dir": bin }));
        let automatic = lib.ok("set_tex_dir", json!({ "dir": dir }));
        assert_eq!(automatic["texDir"], Value::Null);
        assert_ne!(automatic["version"], "Latexmk, stub 1.0");
        assert_eq!(other.tex_dir(), None);
    }
}
