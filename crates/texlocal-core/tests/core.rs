//! Projects, paths, settings and ZIP export, with the UI-facing error strings.

use std::fs;
use std::path::Path;

use serde_json::json;
use tempfile::TempDir;
use texlocal_core::CoreError;
use texlocal_core::paths::{project_root, rel_to_root, safe_path, safe_rel_file};
use texlocal_core::projects::{
    SymbolScan, Symbols, create_file, create_project, file_tree, list_projects, rename_entry,
    rename_project, search_project,
};
use texlocal_core::settings::{Settings, compiled_pdf_path, read_settings, write_settings};
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

fn project(data: &Path, name: &str) -> std::path::PathBuf {
    create_project(data, name, "blank").unwrap();
    project_root(data, name).unwrap()
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
fn settings_reject_unsafe_compiler_inputs() {
    let data = data_dir();
    let root = project(data.path(), "settings-test");

    fails_with(
        write_settings(&root, &json!({ "shellEscape": "false" })),
        "expected a boolean",
    );
    fails_with(
        write_settings(&root, &json!({ "mainFile": "-interaction.tex" })),
        "Path segments cannot start",
    );
    fails_with(
        write_settings(&root, &json!({ "mainFile": "../outside.tex" })),
        "Path escapes project",
    );
}

#[test]
fn a_settings_write_failure_rolls_back_the_filesystem_rename() {
    let data = data_dir();
    let root = project(data.path(), "rename-rollback");
    fs::rename(root.join(".texlocal.json"), root.join("settings.backup")).unwrap();
    fs::create_dir(root.join(".texlocal.json")).unwrap();
    let err = rename_entry(&root, "main.tex", "paper.tex").unwrap_err();
    assert_eq!(err.status, 500);
    assert!(root.join("main.tex").is_file());
    assert!(!root.join("paper.tex").exists());
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
    let data = data_dir();
    let root = project(data.path(), "rename-test");
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
    // reaches latexmk's command line, may not start with one. Deleting one is
    // covered in projects.rs, against a stand-in for the platform trash.
    create_file(&root, "-draft.tex", false).unwrap();
    let result = rename_entry(&root, "-draft.tex", "-notes/-draft.tex").unwrap();
    assert_eq!(result.to, "-notes/-draft.tex");
    assert!(root.join("-notes/-draft.tex").is_file());
}

#[test]
fn a_case_only_rename_works_on_case_insensitive_volumes_too() {
    let data = data_dir();
    let root = project(data.path(), "case-test");
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
    let data = data_dir();
    let root = project(data.path(), "X");
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
fn path_traversal_is_rejected_at_every_boundary() {
    let data = data_dir();
    let root = project(data.path(), "paths-test");
    fails_with(project_root(data.path(), "../etc"), "Bad project id");
    // A folder inside a project is not a project of its own.
    create_file(&root, "chapters/intro.tex", false).unwrap();
    assert_eq!(
        project_root(data.path(), "paths-test/chapters")
            .unwrap_err()
            .status,
        400
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
}

#[cfg(unix)]
#[test]
fn an_unreadable_folder_or_file_does_not_fail_the_scans() {
    use std::os::unix::fs::PermissionsExt;
    let data = data_dir();
    let root = project(data.path(), "locked-test");
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

#[cfg(unix)]
#[test]
fn existing_symlink_ancestors_cannot_escape_the_project() {
    let data = data_dir();
    let root = project(data.path(), "symlink-boundary");
    let outside = tempfile::tempdir().unwrap();
    fs::write(outside.path().join("secret.tex"), "secret").unwrap();
    std::os::unix::fs::symlink(outside.path(), root.join("outside")).unwrap();
    for path in ["outside/secret.tex", "outside/new/sub/file.tex"] {
        fails_with(safe_path(&root, path), "Path escapes project");
        fails_with(safe_rel_file(&root, path), "Path escapes project");
    }
}

// Not gated: the settings name's case aliases are reserved on every platform
// on purpose, because macOS volumes are case-insensitive too.
#[test]
fn the_settings_file_and_its_case_aliases_are_not_reachable_through_the_file_api() {
    let data = data_dir();
    let root = project(data.path(), "reserved-test");
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

// A link inside the project is held to its target's rules (#26).
#[cfg(unix)]
#[test]
fn links_to_reserved_paths_are_held_to_their_rules() {
    use std::os::unix::fs::symlink;
    use texlocal_core::paths::safe_write_path;
    let data = data_dir();
    let root = project(data.path(), "reserved-links");
    fs::write(root.join(".texlocal.json"), "{}").unwrap();
    fs::write(root.join("main.tex"), "x").unwrap();
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
fn compiled_pdf_path_derives_from_a_nested_main_file() {
    let data = data_dir();
    let root = project(data.path(), "pdfpath-test");
    create_file(&root, "chapters/paper.tex", false).unwrap();
    write_settings(&root, &json!({ "mainFile": "chapters/paper.tex" })).unwrap();
    assert_eq!(
        compiled_pdf_path(&root).unwrap(),
        root.join("build").join("paper.pdf")
    );
}

#[cfg(unix)]
#[test]
fn files_the_app_makes_get_the_mode_any_new_file_gets() {
    use std::os::unix::fs::PermissionsExt;
    let data = data_dir();
    let root = project(data.path(), "modes");
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
    let data = data_dir();
    let root = project(data.path(), "zip-test");
    create_file(&root, "chapters/intro.tex", false).unwrap();
    create_file(&root, "sub/.texlocal.json", false).unwrap();
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build").join("main.pdf"), "fake").unwrap();
    let dest = data.path().join("out.zip");
    export_zip(&root, &dest).unwrap();
    let names = zip_names(&dest);
    assert!(names.contains(&"main.tex".to_string()), "{names:?}");
    assert!(
        names.contains(&"chapters/intro.tex".to_string()),
        "{names:?}"
    );
    assert!(
        names.contains(&"sub/.texlocal.json".to_string()),
        "{names:?}"
    );
    assert!(!names.iter().any(|n| n.starts_with("build")), "{names:?}");
    assert!(!names.contains(&".texlocal.json".to_string()), "{names:?}");

    // A destination inside the project can replace an old file there, and
    // neither it nor its temporary file lands in the archive.
    let inside = root.join("project.zip");
    fs::write(&inside, "old incomplete archive").unwrap();
    export_zip(&root, &inside).unwrap();
    let names = zip_names(&inside);
    assert!(!names.contains(&"project.zip".to_string()), "{names:?}");
    assert!(
        !names.iter().any(|name| name.contains(".texlocal-")),
        "{names:?}"
    );
}

#[test]
fn zip_export_dates_entries_as_their_files_and_leaves_os_litter_out() {
    let data = data_dir();
    let root = project(data.path(), "dated-zip");
    fs::create_dir_all(root.join("figs")).unwrap();
    for litter in [".DS_Store", "figs/.DS_Store"] {
        fs::write(root.join(litter), "x").unwrap();
    }
    fs::write(root.join(".latexmkrc"), "$pdf_mode = 1;").unwrap();
    let dest = data.path().join("out.zip");
    export_zip(&root, &dest).unwrap();

    let names = zip_names(&dest);
    assert!(names.contains(&".latexmkrc".to_string()), "{names:?}");
    assert!(!names.iter().any(|n| n.contains("DS_Store")), "{names:?}");
    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let dated = archive
        .by_name("main.tex")
        .unwrap()
        .last_modified()
        .unwrap();
    let modified = fs::metadata(root.join("main.tex"))
        .unwrap()
        .modified()
        .unwrap();
    let local = chrono::DateTime::<chrono::Local>::from(modified);
    use chrono::{Datelike, Timelike};
    assert_eq!(
        (
            dated.year(),
            dated.month(),
            dated.day(),
            dated.hour(),
            dated.minute()
        ),
        (
            local.year() as u16,
            local.month() as u8,
            local.day() as u8,
            local.hour() as u8,
            local.minute() as u8
        )
    );
}

#[test]
fn search_folds_case_cuts_its_snippet_at_the_match_and_stops_at_the_limit() {
    let data = data_dir();
    let root = project(data.path(), "search");
    fs::write(root.join("ascii.tex"), "One\nThe THEOREM holds\n").unwrap();
    fs::write(root.join("accents.tex"), "L'ÉCOLE Normale\nStraße\n").unwrap();
    // An image, though SVG is text: its hits would open as a picture.
    fs::write(root.join("figure.svg"), "<text>theorem</text>\n").unwrap();
    let hits = search_project(&root, "theorem", 50).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].file, "ascii.tex");
    assert_eq!(hits[0].line, 2);
    assert_eq!(hits[0].matched, "THEOREM");
    let hits = search_project(&root, "école", 50).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].matched, "ÉCOLE");
    assert!(search_project(&root, "zzz", 50).unwrap().is_empty());
    // An ASCII match in a file that also contains Unicode.
    fs::write(root.join("mixed.tex"), "Café\nsee Lemma 3\n").unwrap();
    let hits = search_project(&root, "lemma", 50).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].line, 2);
    assert_eq!(hits[0].before, "see ");
    assert_eq!(hits[0].matched, "Lemma");
    // After characters of several bytes, and one whose lowercase is two
    // characters, the snippet still cuts at the match.
    fs::write(root.join("wide.tex"), "Çà İstanbul, GRÖSSE und Größe\n").unwrap();
    let hits = search_project(&root, "größe", 50).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].before, "Çà İstanbul, GRÖSSE und ");
    assert_eq!(hits[0].matched, "Größe");
    // A hit carries the text either side of it.
    fs::write(root.join("quick.tex"), "the quick brown fox jumps\n").unwrap();
    let hits = search_project(&root, "brown", 50).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].before, "the quick ");
    assert_eq!(hits[0].matched, "brown");
    assert_eq!(hits[0].after, " fox jumps");
    // U+0130 and the Kelvin sign both lowercase into plain ASCII.
    fs::write(root.join("kelvin.tex"), "measured 5 \u{212A} today\n").unwrap();
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

/// Only the project's own top-level build/ is compile output. A `build` deeper
/// in the tree is the author's: file_tree lists it and export_zip archives it,
/// so search and the symbol scan must see it too.
#[test]
fn only_the_top_level_build_folder_stays_out_of_the_scans() {
    let data = data_dir();
    let root = project(data.path(), "build-scans");
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
    assert_eq!(
        hits.iter().map(|h| h.file.as_str()).collect::<Vec<_>>(),
        vec!["chapters/build/notes.tex"],
    );
    let labels = scan_symbols(&root).unwrap().labels;
    assert!(labels.contains(&"deep:one".to_string()));
    assert!(!labels.contains(&"gen:one".to_string()));
}

#[test]
fn the_build_folder_name_is_reserved_at_the_top_in_any_case() {
    let data = data_dir();
    let root = project(data.path(), "reserved-build");
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
    let data = data_dir();
    let root = project(data.path(), "dated");
    // Saving a file in place leaves its folder's date alone.
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
    let main = fs::File::options()
        .write(true)
        .open(root.join("main.tex"))
        .unwrap();
    main.set_modified(later).unwrap();
    let expected = later
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    assert_eq!(list_projects(data.path()).unwrap()[0].mtime, expected);
}

#[test]
fn symbol_scan_survives_both_a_bad_byte_and_a_unicode_space() {
    // Plenty of .bib and .tex files are still Latin-1. A Unicode-mode pattern
    // run over the raw bytes cannot step across 0xFC and drops the whole entry
    // containing it; decoding the file first keeps it, lossily.
    let data = data_dir();
    let root = project(data.path(), "latin1");
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

    let found = scan_symbols(&root).unwrap();
    assert!(
        found.citations.iter().any(|c| c.contains("ller2020")),
        "the entry carrying the byte was dropped: {:?}",
        found.citations
    );
    assert!(
        found.citations.contains(&"Smith2020".to_string()),
        "a non-breaking space was swallowed into the key: {:?}",
        found.citations
    );
    assert!(
        found.citations.contains(&"Jones2021".to_string()),
        "an entry was dropped over a non-breaking space: {:?}",
        found.citations
    );
    assert!(
        found.citations.contains(&"ok2021".to_string()),
        "{:?}",
        found.citations
    );
    assert!(
        found.labels.iter().any(|l| l.contains("ller")),
        "the label carrying the byte was dropped: {:?}",
        found.labels
    );
    assert!(
        found.labels.contains(&"fig:ok".to_string()),
        "{:?}",
        found.labels
    );
}

#[test]
fn symbol_scan_reads_bibitems_skips_comments_and_keeps_file_order() {
    let data = data_dir();
    let root = project(data.path(), "bibitems");
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
    fs::write(
        root.join("z.tex"),
        "\\label{shared}\\label{last}\\bibitem{two}",
    )
    .unwrap();
    fs::write(
        root.join("a.tex"),
        "\\label{first}\\label{shared}\\bibitem{one}",
    )
    .unwrap();
    fs::write(root.join("refs.bib"), "@article{one,}\n@article{two,}").unwrap();
    let found = scan_symbols(&root).unwrap();
    assert_eq!(found.labels, ["first", "shared", "last"]);
    assert_eq!(found.citations, ["one", "two"]);
}

#[test]
fn the_file_tree_lists_folders_first_then_names_ignoring_case() {
    let data = data_dir();
    let root = project(data.path(), "tree-order");
    for file in ["c.tex", "B.tex", "Zeta/z.tex", "beta/y.tex", ".hidden.tex"] {
        create_file(&root, file, false).unwrap();
    }
    let tree = file_tree(&root).unwrap();
    let names: Vec<&str> = tree.iter().map(|n| n.name.as_str()).collect();
    assert_eq!(names, ["beta", "Zeta", "B.tex", "c.tex", "main.tex"]);
    assert_eq!(tree[1].kind, "dir");
    assert_eq!(tree[1].children.as_ref().unwrap()[0].path, "Zeta/z.tex");
    assert!(tree[2].children.is_none());
}

#[test]
fn rel_to_root_maps_tool_output_back_into_the_project() {
    let root = Path::new("/data/P");
    assert_eq!(
        rel_to_root(root, Path::new("/data/P/./ch/../ch/intro.tex")).as_deref(),
        Some("ch/intro.tex")
    );
    assert_eq!(rel_to_root(root, Path::new("/data/P")), None);
    assert_eq!(rel_to_root(root, Path::new("/data/P/../Q/a.tex")), None);
    assert_eq!(rel_to_root(root, Path::new("/data/PQ/a.tex")), None);
}

#[test]
fn a_settings_write_returns_what_a_later_read_sees() {
    let data = data_dir();
    let root = project(data.path(), "settings-echo");
    fs::write(
        root.join(".texlocal.json"),
        r#"{ "engine": 3, "custom": "kept" }"#,
    )
    .unwrap();
    let written: Settings = write_settings(&root, &json!({ "shellEscape": true })).unwrap();
    let read = read_settings(&root);
    assert_eq!(
        (&written.main_file, &written.engine, written.shell_escape),
        (&read.main_file, &read.engine, read.shell_escape)
    );
    // The mistyped engine reads as the default; the unknown key survives.
    assert_eq!(read.engine, "pdflatex");
    assert!(read.shell_escape);
    let raw: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(root.join(".texlocal.json")).unwrap()).unwrap();
    assert_eq!(raw["custom"], "kept");

    write_settings(&root, &json!({ "mainFile": "main.tex" })).unwrap();
    let listed = list_projects(data.path()).unwrap();
    assert_eq!(listed[0].id, "settings-echo");
    assert_eq!(listed[0].main_file, "main.tex");
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
    fails_with(
        create_project(data.path(), ".hidden", "blank"),
        "Invalid name",
    );
    fails_with(create_project(data.path(), "   ", "blank"), "Invalid name");
    // A taken name gets the first free number, so a second Untitled works.
    for want in ["Untitled", "Untitled 2", "Untitled 3"] {
        assert_eq!(
            create_project(data.path(), "Untitled", "blank").unwrap().id,
            want
        );
    }
    let info = create_project(data.path(), "  Thesis  ", "report").unwrap();
    assert_eq!((info.id.as_str(), info.name.as_str()), ("Thesis", "Thesis"));
    assert_eq!(info.main_file, "main.tex");
    let root = data.path().join("Thesis");
    assert_eq!(
        names_in(&root),
        [".texlocal.json", "main.tex", "references.bib"]
    );
    assert!(
        fs::read_to_string(root.join("main.tex"))
            .unwrap()
            .contains("{report}")
    );
}

#[cfg(unix)]
#[test]
fn the_tree_scans_and_zip_follow_only_links_to_files_inside_the_project_however_it_is_reached() {
    // A link to a file inside is content. One to a folder, outside, broken or
    // in a loop is not, and must not turn the tree, the scans or the ZIP
    // export into an error, however the project's folder is reached.
    let data = data_dir();
    let root = project(data.path(), "links");
    let outside = tempfile::tempdir().unwrap();
    fs::write(
        outside.path().join("secret.tex"),
        "needle\n\\label{outside-secret}\n",
    )
    .unwrap();
    fs::write(root.join("source.txt"), "needle \\label{linked}").unwrap();
    fs::create_dir(root.join("figures")).unwrap();
    fs::write(root.join("figures/a.txt"), "figure").unwrap();
    let link = |target: &Path, name: &str| {
        std::os::unix::fs::symlink(target, root.join(name)).unwrap();
    };
    link(&root.join("source.txt"), "linked.tex");
    link(&outside.path().join("secret.tex"), "external.tex");
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
        let mut hits: Vec<_> = search_project(base, "needle", 10)
            .unwrap()
            .into_iter()
            .map(|hit| hit.file)
            .collect();
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
