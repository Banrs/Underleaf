//! Projects, paths, settings and ZIP export, with the UI-facing error strings.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;
use tempfile::TempDir;
use texlocal_core::CoreError;
use texlocal_core::import::import_project;
use texlocal_core::paths::{project_root, safe_path, safe_rel_file, source_rel};
use texlocal_core::projects::{
    SymbolScan, Symbols, create_file, create_project, file_tree, list_projects, rename_entry,
    rename_project, search_project,
};
use texlocal_core::service::Service;
use texlocal_core::settings::{read_settings, write_settings};
use texlocal_core::zipexport::export_zip;

/// A project's labels and citations, read afresh.
fn scan_symbols(root: &Path) -> Result<Symbols, CoreError> {
    SymbolScan::default().scan(root)
}

fn data_dir() -> TempDir {
    tempfile::Builder::new()
        .prefix("texlocal-projects-")
        .tempdir()
        .unwrap()
}

/// A library holding one blank project, `name`, and the project's folder.
fn project(name: &str) -> (TempDir, PathBuf) {
    let data = data_dir();
    create_project(data.path(), name, "blank").unwrap();
    let root = project_root(data.path(), name).unwrap();
    (data, root)
}

#[track_caller]
fn fails_with<T: std::fmt::Debug>(result: Result<T, CoreError>, text: &str) {
    let message = result.unwrap_err().message;
    assert!(message.contains(text), "{message:?} lacks {text:?}");
}

fn zip_names(path: &Path) -> Vec<String> {
    let archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
    archive.file_names().map(str::to_owned).collect()
}

#[test]
fn a_settings_patch_changes_only_its_keys_and_returns_what_a_later_read_sees() {
    let (data, root) = project("settings-echo");
    let file = root.join(".texlocal.json");
    let saved = r#"{ "engine": "xelatex", "stopOnFirstError": 3, "custom": "kept" }"#;
    fs::write(&file, saved).unwrap();
    let written = write_settings(&root, &json!({ "shellEscape": true, "unknown": 1 })).unwrap();
    // The file's engine stays, its mistyped flag reads as the default, and
    // its unknown key survives.
    let expected = json!({
        "mainFile": "main.tex", "engine": "xelatex", "shellEscape": true, "stopOnFirstError": false
    });
    assert_eq!(json!(written), expected);
    assert_eq!(json!(read_settings(&root)), expected);
    let raw: serde_json::Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    assert_eq!(raw["custom"], "kept");

    // A patch that fails writes nothing, its valid keys included.
    let before = fs::read(&file).unwrap();
    for (bad, why) in [
        (
            json!({ "engine": "word", "shellEscape": false }),
            "Unknown engine",
        ),
        (json!({ "shellEscape": "false" }), "expected a boolean"),
        (
            json!({ "mainFile": "-interaction.tex" }),
            "Path segments cannot start",
        ),
        (
            json!({ "mainFile": "../outside.tex" }),
            "Path escapes project",
        ),
        (json!([1]), "Invalid settings"),
    ] {
        fails_with(write_settings(&root, &bad), why);
    }
    assert_eq!(fs::read(&file).unwrap(), before);

    write_settings(&root, &json!({ "mainFile": "main.tex" })).unwrap();
    let listed = list_projects(data.path()).unwrap().remove(0);
    assert_eq!([listed.id, listed.main_file], ["settings-echo", "main.tex"]);
}

#[test]
fn a_rename_that_cannot_write_the_settings_is_undone_and_leaves_them_as_they_were() {
    let (_data, root) = project("broken-settings");
    let file = root.join(".texlocal.json");
    let broken = "{ \"mainFile\": \"paper.tex\", \"engine\": \"xelatex\", }";
    fs::write(&file, broken).unwrap();
    // A rename that moves the main file would write it, so it is undone.
    assert_eq!(
        rename_entry(&root, "main.tex", "a.tex").unwrap_err().status,
        409
    );
    assert!(root.join("main.tex").is_file() && !root.join("a.tex").exists());
    // One that leaves it alone goes through, and the file is as it was.
    create_file(&root, "b.tex", false).unwrap();
    rename_entry(&root, "b.tex", "c.tex").unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), broken);
}

fn names_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn a_rename_takes_the_main_file_along_only_when_it_holds_it_and_keeps_to_the_rules() {
    let (_data, root) = project("rename-test");
    create_file(&root, "chapters/main.tex", false).unwrap();
    create_file(&root, "chapters2/other.tex", false).unwrap();
    // A folder holding the main file takes it along.
    write_settings(&root, &json!({ "mainFile": "chapters/main.tex" })).unwrap();
    let result = rename_entry(&root, "chapters", "content").unwrap();
    assert_eq!(result.main_file, "content/main.tex");
    assert_eq!(read_settings(&root).main_file, "content/main.tex");
    // One that merely shares a name's start with the main file's folder does not.
    create_file(&root, "chapters/x.tex", false).unwrap();
    write_settings(&root, &json!({ "mainFile": "chapters2/other.tex" })).unwrap();
    rename_entry(&root, "chapters", "moved").unwrap();
    assert_eq!(read_settings(&root).main_file, "chapters2/other.tex");
    // A folder can't be moved into itself.
    let err = rename_entry(&root, "moved", "moved/old/moved").unwrap_err();
    assert_eq!(err.status, 400, "{}", err.message);
    assert_eq!(names_in(&root.join("moved")), ["x.tex"]);
    // create_entry and uploads accept a leading "-"; only the main file, which
    // reaches latexmk's command line, may not start with one.
    create_file(&root, "-draft.tex", false).unwrap();
    let result = rename_entry(&root, "-draft.tex", "-notes/-draft.tex").unwrap();
    assert_eq!(result.to, "-notes/-draft.tex");
    assert!(root.join("-notes/-draft.tex").is_file());
}

#[test]
fn a_case_only_rename_works_on_case_insensitive_volumes_too() {
    let (data, root) = project("case-test");
    create_file(&root, "Figures/plot.tex", false).unwrap();

    let result = rename_entry(&root, "main.tex", "Main.tex").unwrap();
    assert_eq!(result.main_file, "Main.tex");
    assert_eq!(read_settings(&root).main_file, "Main.tex");
    rename_entry(&root, "Figures", "figures").unwrap();
    assert_eq!(names_in(&root), [".texlocal.json", "Main.tex", "figures"]);

    // A different entry in the way is still a conflict.
    create_file(&root, "other.tex", false).unwrap();
    let err = rename_entry(&root, "other.tex", "Main.tex").unwrap_err();
    assert_eq!(err.status, 409);

    rename_project(data.path(), "case-test", "Case-Test", |_| Ok(())).unwrap();
    assert_eq!(names_in(data.path()), ["Case-Test"]);
    create_project(data.path(), "second", "blank").unwrap();
    let err = rename_project(data.path(), "second", "Case-Test", |_| panic!("moved")).unwrap_err();
    assert_eq!(err.status, 409);
}

/// `before_move` runs once the rename is sure to go ahead: a project made
/// then gets another name, not the one the rename is taking.
#[test]
fn a_project_made_while_a_rename_is_under_way_gets_another_name() {
    let (data, root) = project("X");
    fs::write(root.join("main.tex"), "the user's").unwrap();
    let mut made = None;
    let renamed = rename_project(data.path(), "X", "R", |_| {
        made = Some(create_project(data.path(), "R", "blank")?.name);
        Ok(())
    });
    let renamed = renamed.unwrap_or_else(|e| panic!("rename: {} {}", e.status, e.message));
    assert_eq!(renamed.name, "R");
    assert_eq!(made.as_deref(), Some("R 2"));
    let text = fs::read_to_string(data.path().join("R/main.tex")).unwrap();
    assert_eq!(text, "the user's");

    // A rename that doesn't go ahead leaves no folder of the new name.
    let stopped = rename_project(data.path(), "R", "S", |_| Err(CoreError::conflict("no")));
    assert_eq!(stopped.unwrap_err().status, 409);
    assert_eq!(names_in(data.path()), ["R", "R 2"]);
}

#[test]
fn path_traversal_and_the_settings_file_are_rejected_at_every_boundary() {
    let (data, root) = project("paths-test");
    fails_with(project_root(data.path(), "../etc"), "Bad project id");
    // A folder inside a project is not a project of its own.
    create_file(&root, "chapters/intro.tex", false).unwrap();
    fails_with(
        project_root(data.path(), "paths-test/chapters"),
        "Bad project id",
    );
    assert_eq!(project_root(data.path(), "./paths-test/").unwrap(), root);
    assert_eq!(
        safe_rel_file(&root, "./chapters/../chapters//intro.tex").unwrap(),
        "chapters/intro.tex"
    );
    for path in ["../x", "a/../../b", ".", "/x"] {
        fails_with(safe_path(&root, path), "Path escapes project");
    }
    fails_with(safe_path(&root, ""), "Missing path");

    // The settings file's case aliases are reserved on every platform on
    // purpose, as macOS volumes are case-insensitive too.
    for name in [
        ".texlocal.json",
        ".TEXLOCAL.JSON",
        ".TexLocal.Json",
        ".texlocal.JSON",
    ] {
        fails_with(safe_path(&root, name), "Reserved file");
    }
    assert!(safe_path(&root, "sub/.texlocal.json").is_ok());
}

#[cfg(unix)]
#[test]
fn an_unreadable_folder_or_file_does_not_fail_the_scans() {
    use std::os::unix::fs::PermissionsExt;
    let (_data, root) = project("locked-test");
    fs::write(root.join("main.tex"), "\\label{sec:open} needle\n").unwrap();
    create_file(&root, "locked/inside.tex", false).unwrap();
    fs::write(root.join("secret.tex"), "needle").unwrap();
    let lock = |path: &Path, mode| fs::set_permissions(path, fs::Permissions::from_mode(mode));
    lock(&root.join("locked"), 0o000).unwrap();
    lock(&root.join("secret.tex"), 0o000).unwrap();
    if fs::read_dir(root.join("locked")).is_ok() {
        // Running as root, where permissions don't lock anything.
        lock(&root.join("locked"), 0o755).unwrap();
        return;
    }

    let tree = file_tree(&root);
    let hits = search_project(&root, "needle", 100);
    let symbols = scan_symbols(&root);
    lock(&root.join("locked"), 0o755).unwrap();

    let tree = tree.unwrap();
    let locked = tree.iter().find(|n| n.name == "locked").unwrap();
    assert!(locked.children.as_ref().unwrap().is_empty());
    let hits = hits.unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].file, "main.tex");
    assert_eq!(symbols.unwrap().labels, ["sec:open"]);
}

/// A link inside the project is held to its target's rules (#26), and one
/// out of it leads nowhere, however much of the path exists.
#[cfg(unix)]
#[test]
fn links_are_held_to_the_rules_of_where_they_lead() {
    use std::os::unix::fs::symlink;
    use texlocal_core::paths::safe_write_path;
    let (_data, root) = project("reserved-links");
    let outside = tempfile::tempdir().unwrap();
    fs::write(outside.path().join("secret.tex"), "secret").unwrap();
    symlink(outside.path(), root.join("outside")).unwrap();
    for path in ["outside/secret.tex", "outside/new/sub/file.tex"] {
        fails_with(safe_path(&root, path), "Path escapes project");
        fails_with(safe_rel_file(&root, path), "Path escapes project");
    }
    fs::create_dir_all(root.join("build")).unwrap();
    symlink(".texlocal.json", root.join("alias.json")).unwrap();
    symlink(".", root.join("here")).unwrap();
    symlink("build", root.join("output")).unwrap();
    symlink("main.tex", root.join("link.tex")).unwrap();
    fails_with(safe_write_path(&root, "alias.json"), "Reserved file");
    fails_with(safe_path(&root, "alias.json"), "Reserved file");
    fails_with(
        safe_write_path(&root, "here/.texlocal.json"),
        "Reserved file",
    );
    fails_with(safe_write_path(&root, "output/main.pdf"), "compiled PDF");
    fails_with(safe_write_path(&root, "here/build/x.tex"), "compiled PDF");
    // Reading the output through a link, and ordinary links, stay as they were.
    assert!(safe_path(&root, "output/main.pdf").is_ok());
    assert!(safe_write_path(&root, "link.tex").is_ok());
    assert!(safe_write_path(&root, "here/notes.tex").is_ok());
}

#[test]
fn the_build_output_is_named_after_a_nested_main_file() {
    let (_data, root) = project("pdfpath-test");
    create_file(&root, "chapters/paper.tex", false).unwrap();
    let settings = write_settings(&root, &json!({ "mainFile": "chapters/paper.tex" })).unwrap();
    let pdf = settings.output(&root, "pdf").unwrap();
    assert_eq!(pdf, root.join("build").join("paper.pdf"));
}

#[cfg(unix)]
#[test]
fn files_the_app_makes_get_the_mode_any_new_file_gets() {
    use std::os::unix::fs::PermissionsExt;
    let (data, root) = project("modes");
    let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
    let usual = mode(&root.join("main.tex"));
    create_file(&root, "notes.tex", false).unwrap();
    assert_eq!(mode(&root.join("notes.tex")), usual);
    assert_eq!(mode(&root.join(".texlocal.json")), usual);
    let dest = data.path().join("export.zip");
    export_zip(&root, &dest).unwrap();
    assert_eq!(mode(&dest), usual);
}

#[test]
fn zip_export_excludes_build_and_settings_and_never_archives_itself() {
    let (data, root) = project("zip-test");
    create_file(&root, "chapters/intro.tex", false).unwrap();
    create_file(&root, "sub/.texlocal.json", false).unwrap();
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build").join("main.pdf"), "fake").unwrap();
    let dest = data.path().join("out.zip");
    export_zip(&root, &dest).unwrap();
    // A nested settings file is the author's.
    assert_eq!(
        zip_names(&dest),
        [
            "chapters/",
            "chapters/intro.tex",
            "main.tex",
            "sub/",
            "sub/.texlocal.json"
        ]
    );

    // A destination inside the project can replace an old file there, and
    // neither it nor its temporary file lands in the archive.
    let inside = root.join("project.zip");
    fs::write(&inside, "old incomplete archive").unwrap();
    export_zip(&root, &inside).unwrap();
    assert_eq!(zip_names(&inside), zip_names(&dest));
}

#[test]
fn zip_export_dates_entries_as_their_files() {
    let (data, root) = project("dated-zip");
    let dest = data.path().join("out.zip");
    export_zip(&root, &dest).unwrap();
    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let dated = archive.by_name("main.tex").unwrap().last_modified();
    let modified = fs::metadata(root.join("main.tex")).unwrap().modified();
    let local = chrono::DateTime::<chrono::Local>::from(modified.unwrap());
    // To the minute, as ZIP dates in steps of two seconds.
    let minute = local.format("%Y-%m-%d %H:%M").to_string();
    assert_eq!(dated.unwrap().to_string()[..16], minute);
}

#[test]
fn search_folds_case_cuts_its_snippet_at_the_match_and_stops_at_the_limit() {
    let (_data, root) = project("search");
    for (file, text) in [
        ("ascii.tex", "One\nThe THEOREM holds\n"),
        ("accents.tex", "L'ÉCOLE Normale\nStraße\n"),
        // An image, though SVG is text: its hits would open as a picture.
        ("figure.svg", "<text>theorem</text>\n"),
        // An ASCII match in a file that also contains Unicode.
        ("mixed.tex", "Café\nsee Lemma 3\n"),
        ("wide.tex", "Çà İstanbul, GRÖSSE und Größe\n"),
        ("quick.tex", "the quick brown fox jumps\n"),
        ("kelvin.tex", "measured 5 \u{212A} today\n"),
    ] {
        fs::write(root.join(file), text).unwrap();
    }
    // The one hit, as "file:line before[match]after".
    let hit = |query: &str| {
        let hits = search_project(&root, query, 50).unwrap();
        assert_eq!(hits.len(), 1, "{query}");
        let hit = &hits[0];
        let (file, line) = (&hit.file, hit.line);
        format!("{file}:{line} {}[{}]{}", hit.before, hit.matched, hit.after)
    };
    assert_eq!(hit("theorem"), "ascii.tex:2 The [THEOREM] holds");
    assert_eq!(hit("école"), "accents.tex:1 L'[ÉCOLE] Normale");
    assert!(search_project(&root, "zzz", 50).unwrap().is_empty());
    assert_eq!(hit("lemma"), "mixed.tex:2 see [Lemma] 3");
    // After characters of several bytes, and one whose lowercase is two
    // characters, the snippet still cuts at the match.
    assert_eq!(hit("größe"), "wide.tex:1 Çà İstanbul, GRÖSSE und [Größe]");
    assert_eq!(hit("brown"), "quick.tex:1 the quick [brown] fox jumps");
    // U+0130 and the Kelvin sign both lowercase into plain ASCII.
    let files = |query: &str| -> Vec<String> {
        let hits = search_project(&root, query, 50).unwrap();
        hits.into_iter().map(|hit| hit.file).collect()
    };
    assert!(files("istanbul").contains(&"wide.tex".to_string()));
    assert!(files("k").contains(&"kelvin.tex".to_string()));
    // The limit cuts the hits off.
    fs::write(root.join("many.tex"), "needle\n".repeat(20)).unwrap();
    let hits = search_project(&root, "needle", 5).unwrap();
    assert_eq!(hits.len(), 5);
    assert!(hits.iter().all(|h| h.file == "many.tex"));
}

/// An editor host selects the match itself, so a hit places it in UTF-16
/// units of the line as written, not of its lowercased copy.
#[test]
fn a_hit_places_its_match_in_utf16_units_of_the_line() {
    let (_data, root) = project("search-place");
    let hit = |text: &str, query: &str| {
        fs::write(root.join("main.tex"), text).unwrap();
        let mut hits = search_project(&root, query, 50).unwrap();
        assert_eq!(hits.len(), 1, "{text:?}");
        let hit = hits.remove(0);
        (hit.line, hit.column, hit.length, hit.matched)
    };
    // The first match on its line.
    let place = hit("intro\nthe brown, brown fox\n", "brown");
    assert_eq!(place, (2, 4, 5, "brown".into()));
    // An emoji is two units; so is a match's character beyond the BMP.
    let place = hit("\u{1F600} see a\u{1D538}b\n", "a\u{1D538}b");
    assert_eq!(place, (1, 7, 4, "a\u{1D538}b".into()));
    // İ, ẞ and the Kelvin sign shrink in UTF-8 as they lowercase.
    let place = hit("İ \u{212A} \u{1F600} GRÖẞE und\n", "größe");
    assert_eq!(place, (1, 7, 5, "GRÖẞE".into()));
}

/// Only the project's own top-level build/ is compile output. A `build` deeper
/// in the tree is the author's: file_tree lists it and export_zip archives it,
/// so search and the symbol scan must see it too.
#[test]
fn only_the_top_level_build_folder_stays_out_of_the_scans() {
    let (_data, root) = project("build-scans");
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.tex"), "needle \\label{gen:one}\n").unwrap();
    fs::write(root.join("build/main.log"), "needle in the build dir").unwrap();
    create_file(&root, "chapters/build/notes.tex", false).unwrap();
    fs::write(
        root.join("chapters/build/notes.tex"),
        "a needle and \\label{deep:one}\n",
    )
    .unwrap();

    let hits = search_project(&root, "needle", 10).unwrap();
    let files: Vec<_> = hits.iter().map(|h| h.file.as_str()).collect();
    assert_eq!(files, ["chapters/build/notes.tex"]);
    let labels = scan_symbols(&root).unwrap().labels;
    assert!(labels.contains(&"deep:one".to_string()));
    assert!(!labels.contains(&"gen:one".to_string()));
}

#[test]
fn the_build_folder_name_is_reserved_at_the_top_in_any_case() {
    let (_data, root) = project("reserved-build");
    create_file(&root, "figs/a.png", false).unwrap();
    fails_with(create_file(&root, "build", true), "compiled PDF");
    fails_with(create_file(&root, "BUILD/x.tex", false), "compiled PDF");
    fails_with(rename_entry(&root, "figs", "Build"), "compiled PDF");
    // Deeper, the name is the author's.
    create_file(&root, "figs/build", true).unwrap();
    // A folder made elsewhere in another case stays hidden as output.
    fs::create_dir(root.join("Build")).unwrap();
    assert!(file_tree(&root).unwrap().iter().all(|n| n.name != "Build"));
}

#[test]
fn a_project_is_dated_by_its_newest_file() {
    let (data, root) = project("dated");
    // Saving a file in place leaves its folder's date alone.
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
    let main = fs::File::options().write(true).open(root.join("main.tex"));
    main.unwrap().set_modified(later).unwrap();
    let since = later.duration_since(std::time::UNIX_EPOCH).unwrap();
    let mtime = list_projects(data.path()).unwrap()[0].mtime;
    assert_eq!(mtime, since.as_millis() as u64);
}

#[test]
fn symbol_scan_survives_both_a_bad_byte_and_a_unicode_space() {
    // Plenty of .bib and .tex files are still Latin-1. A Unicode-mode pattern
    // run over the raw bytes cannot step across 0xFC and drops the whole entry
    // containing it; decoding the file first keeps it, lossily.
    let (_data, root) = project("latin1");
    let mut bib = b"@article{m".to_vec();
    bib.push(0xFC); // 'u-umlaut' in ISO-8859-1; invalid on its own as UTF-8
    bib.extend_from_slice(b"ller2020,\n  title={x}\n}\n@article{ok2021,\n  title={y}\n}\n");
    fs::write(root.join("refs.bib"), &bib).unwrap();

    let mut tex = b"\\label{fig:m".to_vec();
    tex.push(0xFC);
    tex.extend_from_slice(b"ller}\n\\label{fig:ok}\n");
    fs::write(root.join("ch.tex"), &tex).unwrap();

    // Non-breaking spaces, which reference managers and PDF copy-paste emit, are
    // the opposite trap: matching bytes with an ASCII-only `\s` swallows the
    // NBSP into the key and drops an entry whose NBSP sits before the brace.
    fs::write(
        root.join("pasted.bib"),
        "@article{Smith2020\u{00A0},\n  title={x}\n}\n@article\u{00A0}{Jones2021,\n  title={y}\n}\n",
    )
    .unwrap();

    // In file-name order: pasted.bib, then refs.bib. The byte's entries are
    // kept, however it decodes.
    let Symbols { citations, labels } = scan_symbols(&root).unwrap();
    assert_eq!(citations.len(), 4, "{citations:?}");
    assert_eq!(citations[..2], ["Smith2020", "Jones2021"]);
    assert!(citations[2].contains("ller2020") && citations[3] == "ok2021");
    assert_eq!(labels.len(), 2, "{labels:?}");
    assert!(labels[0].contains("ller") && labels[1] == "fig:ok");
}

#[test]
fn symbol_scan_reads_bibitems_skips_comments_and_keeps_file_order() {
    let (_data, root) = project("bibitems");
    fs::write(
        root.join("main.tex"),
        "\\label{kept} % \\label{old}\n% \\bibitem{gone}\n50\\% \\label{after-percent} \\label{fig:}\n\
         \\begin{thebibliography}{9}\n\\bibitem[K]{knuth} Knuth.\n\\bibitem {lamport} Lamport.\n",
    )
    .unwrap();
    let found = scan_symbols(&root).unwrap();
    assert_eq!(found.labels, ["kept", "after-percent"]);
    assert_eq!(found.citations, ["knuth", "lamport"]);

    // Files come in name order, and a repeated symbol keeps its first place.
    fs::remove_file(root.join("main.tex")).unwrap();
    for (file, text) in [
        ("z.tex", "\\label{shared}\\label{last}\\bibitem{two}"),
        ("a.tex", "\\label{first}\\label{shared}\\bibitem{one}"),
        ("refs.bib", "@article{one,}\n@article{two,}"),
    ] {
        fs::write(root.join(file), text).unwrap();
    }
    let found = scan_symbols(&root).unwrap();
    assert_eq!(found.labels, ["first", "shared", "last"]);
    assert_eq!(found.citations, ["one", "two"]);
}

/// What synctex prints as a source maps back into the project, lexically:
/// compile_stub's inverse sync tests the links and reserved paths.
#[test]
fn a_tools_input_path_maps_back_to_the_project_file() {
    let (data, root) = project("P");
    create_project(data.path(), "PQ", "blank").unwrap();
    create_file(&root, "ch/intro.tex", false).unwrap();
    let under = |path: &str| format!("{}{path}", root.display());
    for (input, rel) in [
        (under("/./ch/../ch/intro.tex"), Some("ch/intro.tex")),
        ("./ch/intro.tex".into(), Some("ch/intro.tex")),
        (under(""), None),
        (under("/../PQ/main.tex"), None),
        (under("Q/main.tex"), None),
    ] {
        assert_eq!(source_rel(&root, &input).as_deref(), rel, "{input}");
    }
}

#[cfg(unix)]
#[test]
fn a_new_project_never_lands_on_an_existing_entry_even_a_dangling_link() {
    let data = data_dir();
    std::os::unix::fs::symlink(data.path().join("gone"), data.path().join("linked")).unwrap();
    let info = create_project(data.path(), "linked", "blank").unwrap();
    assert_eq!(info.id, "linked 2");
    assert!(!data.path().join("gone").exists());
}

#[test]
fn new_projects_are_named_sanitized_and_stocked_with_a_template() {
    let data = data_dir();
    for bad in [".hidden", "   "] {
        fails_with(create_project(data.path(), bad, "blank"), "Invalid name");
    }
    // A taken name gets the first free number, so a second Untitled works.
    for want in ["Untitled", "Untitled 2", "Untitled 3"] {
        let made = create_project(data.path(), "Untitled", "blank").unwrap();
        assert_eq!(made.id, want);
    }
    let info = create_project(data.path(), "  Thesis  ", "report").unwrap();
    assert_eq!((info.id.as_str(), info.name.as_str()), ("Thesis", "Thesis"));
    assert_eq!(info.main_file, "main.tex");
    let root = data.path().join("Thesis");
    assert_eq!(
        names_in(&root),
        [".texlocal.json", "main.tex", "references.bib"]
    );
    let main = fs::read_to_string(root.join("main.tex")).unwrap();
    assert!(main.contains("{report}"));
}

#[cfg(unix)]
#[test]
fn the_tree_scans_and_zip_follow_only_links_to_files_inside_the_project_however_it_is_reached() {
    // A link to a file inside is content. One to a folder, outside, broken or
    // in a loop is not, and must not turn the tree, the scans or the ZIP
    // export into an error, however the project's folder is reached.
    let (data, root) = project("links");
    let outside = tempfile::tempdir().unwrap();
    let secret = outside.path().join("secret.tex");
    fs::write(&secret, "needle\n\\label{outside-secret}\n").unwrap();
    fs::write(root.join("source.txt"), "needle \\label{linked}").unwrap();
    fs::create_dir(root.join("figures")).unwrap();
    fs::write(root.join("figures/a.txt"), "figure").unwrap();
    let link = |target: &Path, name: &str| {
        std::os::unix::fs::symlink(target, root.join(name)).unwrap();
    };
    link(&root.join("source.txt"), "linked.tex");
    link(&secret, "external.tex");
    link(&root.join("figures"), "linked-dir");
    link(&root, "loop");
    link(&root.join("gone.tex"), "broken.tex");
    link(&root.join("b.tex"), "a.tex");
    link(&root.join("a.tex"), "b.tex");
    let alias = data.path().join("alias");
    std::os::unix::fs::symlink(&root, &alias).unwrap();

    for base in [&root, &alias] {
        let tree = file_tree(base).unwrap();
        let top: Vec<_> = tree.iter().map(|n| n.path.as_str()).collect();
        assert_eq!(top, ["figures", "linked.tex", "main.tex", "source.txt"]);
        let hits = search_project(base, "needle", 10).unwrap();
        let mut hits: Vec<_> = hits.into_iter().map(|hit| hit.file).collect();
        hits.sort();
        assert_eq!(hits, ["linked.tex", "source.txt"]);
        assert_eq!(scan_symbols(base).unwrap().labels, ["linked"]);
    }
    let dest = data.path().join("out.zip");
    export_zip(&root, &dest).unwrap();
    assert_eq!(
        zip_names(&dest),
        [
            "figures/",
            "figures/a.txt",
            "linked.tex",
            "main.tex",
            "source.txt"
        ]
    );
    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let mut body = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("linked.tex").unwrap(), &mut body).unwrap();
    assert_eq!(body, "needle \\label{linked}");

    // The destination spelled through a link into the project, as when a Save
    // panel hands back /private/var for a data folder under /var: a lexical
    // comparison would archive the ZIP's own half-written temporary file.
    export_zip(&root, &alias.join("again.zip")).unwrap();
    assert_eq!(zip_names(&root.join("again.zip")), zip_names(&dest));
}

#[test]
fn a_project_exported_and_opened_again_keeps_every_file_the_author_made() {
    let (data, root) = project("round-trip");
    create_file(&root, "chapters/intro.tex", false).unwrap();
    for (path, text) in [
        (".latexmkrc", "pdf_mode = 1;"),
        (".gitignore", "build/"),
        (".git/HEAD", "ref"),
        (".DS_Store", "x"),
        ("build/main.pdf", "output"),
    ] {
        let file = root.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, text).unwrap();
    }
    write_settings(&root, &json!({ "engine": "lualatex" })).unwrap();
    let zip = data.path().join("out.zip");
    export_zip(&root, &zip).unwrap();

    let service = Service::new(data.path().join("again"));
    let info = import_project(&service, &zip).unwrap();
    let copy = service.data_dir.join(&info.id);
    let expected = [
        ".gitignore",
        ".latexmkrc",
        ".texlocal.json",
        "chapters",
        "main.tex",
    ];
    assert_eq!(names_in(&copy), expected);
    assert_eq!(
        fs::read_to_string(copy.join(".latexmkrc")).unwrap(),
        "pdf_mode = 1;"
    );
    // The settings are the project's own and are not carried in the archive.
    assert_eq!(read_settings(&copy).engine.as_str(), "pdflatex");
}
