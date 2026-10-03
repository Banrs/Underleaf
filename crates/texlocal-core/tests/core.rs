//! Projects, paths, settings and ZIP export, with the UI-facing error strings.

use std::fs;
use std::path::Path;

use serde_json::json;
use tempfile::TempDir;
use texlocal_core::paths::{project_root, rel_to_root, safe_path, safe_rel_file};
use texlocal_core::projects::{
    create_file, create_project, file_tree, list_projects, rename_entry, rename_project,
    scan_symbols, search_project,
};
use texlocal_core::settings::{compiled_pdf_path, read_settings, write_settings, Settings};
use texlocal_core::zipexport::export_zip;
use texlocal_core::CoreError;

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
        "shellEscape must be a boolean",
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
fn renaming_a_directory_keeps_the_main_file_setting_valid() {
    let data = data_dir();
    let root = project(data.path(), "rename-test");
    create_file(&root, "chapters/main.tex", false).unwrap();
    write_settings(&root, &json!({ "mainFile": "chapters/main.tex" })).unwrap();
    let result = rename_entry(&root, "chapters", "content").unwrap();
    assert_eq!(result.main_file, "content/main.tex");
    assert_eq!(read_settings(&root).main_file, "content/main.tex");
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

#[test]
fn an_entry_named_with_a_leading_dash_can_be_renamed() {
    // create_entry and uploads accept such a name; only the main file, which
    // reaches latexmk's command line, may not start with "-". Deleting one is
    // covered in projects.rs, against a stand-in for the platform trash.
    let data = data_dir();
    let root = project(data.path(), "dash-test");
    create_file(&root, "-draft.tex", false).unwrap();
    let result = rename_entry(&root, "-draft.tex", "-notes/-draft.tex").unwrap();
    assert_eq!(result.to, "-notes/-draft.tex");
    assert!(root.join("-notes/-draft.tex").is_file());
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

    rename_project(data.path(), "case-test", "Case-Test").unwrap();
    assert_eq!(names_in(data.path()), ["Case-Test"]);
    create_project(data.path(), "second", "blank").unwrap();
    let err = rename_project(data.path(), "second", "Case-Test").unwrap_err();
    assert_eq!(err.status, 409);
}

#[test]
fn a_folder_cannot_be_moved_into_itself() {
    let data = data_dir();
    let root = project(data.path(), "into-itself");
    create_file(&root, "chapters/one.tex", false).unwrap();
    let err = rename_entry(&root, "chapters", "chapters/old/chapters").unwrap_err();
    assert_eq!(err.status, 400, "{}", err.message);
    assert_eq!(names_in(&root.join("chapters")), ["one.tex"]);
}

#[test]
fn path_traversal_is_rejected_at_every_boundary() {
    let data = data_dir();
    let root = project(data.path(), "paths-test");
    fails_with(project_root(data.path(), "../etc"), "Bad project id");
    // A folder inside a project is not a project of its own.
    create_file(&root, "chapters/intro.tex", false).unwrap();
    for id in ["paths-test/chapters", r"paths-test\chapters"] {
        assert_eq!(project_root(data.path(), id).unwrap_err().status, 400);
    }
    assert_eq!(project_root(data.path(), "./paths-test/").unwrap(), root);
    for path in ["../x", "a/../../b", ".", r"..\x", r"C:\x"] {
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
    fails_with(
        safe_path(&root, "outside/secret.tex"),
        "Path escapes project",
    );
    fails_with(
        safe_rel_file(&root, "outside/secret.tex"),
        "Path escapes project",
    );
}

#[cfg(unix)]
#[test]
fn implicit_project_scans_skip_external_symlink_files() {
    let data = data_dir();
    let root = project(data.path(), "symlink-scans");
    let outside = tempfile::tempdir().unwrap();
    fs::write(
        outside.path().join("secret.tex"),
        "needle\n\\label{outside-secret}\n",
    )
    .unwrap();
    std::os::unix::fs::symlink(outside.path().join("secret.tex"), root.join("external.tex"))
        .unwrap();

    assert!(search_project(&root, "needle", 50).unwrap().is_empty());
    assert!(scan_symbols(&root).unwrap().labels.is_empty());
    assert!(file_tree(&root)
        .unwrap()
        .iter()
        .all(|node| node.path != "external.tex"));
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

#[cfg(windows)]
#[test]
fn windows_reserved_device_names_are_rejected() {
    let data = data_dir();
    let root = project(data.path(), "windows-aliases");
    assert!(safe_path(&root, "CON.tex").is_err());
    assert!(safe_path(&root, "CONIN$").is_err());
    assert!(safe_path(&root, "COM¹.log").is_err());
    assert!(safe_path(&root, "paper.tex.").is_err());
    assert!(safe_path(&root, "paper.tex ").is_err());
}

#[test]
fn project_names_are_sanitized() {
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

#[test]
fn renaming_an_unrelated_entry_leaves_the_main_file_alone() {
    let data = data_dir();
    let root = project(data.path(), "rename-unrelated");
    create_file(&root, "chapters/main.tex", false).unwrap();
    create_file(&root, "chapters2/other.tex", false).unwrap();
    write_settings(&root, &json!({ "mainFile": "chapters2/other.tex" })).unwrap();
    rename_entry(&root, "chapters", "content").unwrap();
    assert_eq!(read_settings(&root).main_file, "chapters2/other.tex");
}

#[test]
fn a_backslash_main_file_from_an_old_settings_file_still_works() {
    let data = data_dir();
    let root = project(data.path(), "backslash-test");
    create_file(&root, "chapters/paper.tex", false).unwrap();
    fs::write(
        root.join(".texlocal.json"),
        r#"{ "mainFile": "chapters\\paper.tex" }"#,
    )
    .unwrap();
    assert_eq!(
        safe_rel_file(&root, &read_settings(&root).main_file).unwrap(),
        "chapters/paper.tex"
    );
    assert_eq!(
        compiled_pdf_path(&root).unwrap(),
        root.join("build").join("paper.pdf")
    );
}

#[cfg(unix)]
#[test]
fn zip_export_keeps_safe_file_links_but_skips_directory_and_external_links() {
    let data = data_dir();
    let root = project(data.path(), "zip-symlink-test");
    fs::write(root.join("real.tex"), "shared").unwrap();
    fs::create_dir(root.join("figures")).unwrap();
    fs::write(root.join("figures/a.txt"), "figure").unwrap();
    let outside = tempfile::tempdir().unwrap();
    fs::write(outside.path().join("secret.tex"), "secret").unwrap();
    std::os::unix::fs::symlink(root.join("real.tex"), root.join("linked.tex")).unwrap();
    std::os::unix::fs::symlink(root.join("figures"), root.join("linked-dir")).unwrap();
    std::os::unix::fs::symlink(outside.path().join("secret.tex"), root.join("outside.tex"))
        .unwrap();
    std::os::unix::fs::symlink(root.join("gone.tex"), root.join("broken.tex")).unwrap();
    let dest = data.path().join("out.zip");
    export_zip(&root, &dest).unwrap();
    let names = zip_names(&dest);
    assert!(names.contains(&"linked.tex".to_string()), "{names:?}");
    assert!(
        !names.iter().any(|name| name.starts_with("linked-dir")),
        "{names:?}"
    );
    assert!(!names.contains(&"outside.tex".to_string()), "{names:?}");
    assert!(!names.contains(&"broken.tex".to_string()), "{names:?}");
    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let mut linked = archive.by_name("linked.tex").unwrap();
    let mut body = String::new();
    std::io::Read::read_to_string(&mut linked, &mut body).unwrap();
    assert_eq!(body, "shared");
}

#[test]
fn zip_export_can_replace_a_destination_inside_the_project_without_archiving_itself() {
    let data = data_dir();
    let root = project(data.path(), "zip-self-test");
    let dest = root.join("project.zip");
    fs::write(&dest, "old incomplete archive").unwrap();
    export_zip(&root, &dest).unwrap();
    let names = zip_names(&dest);
    assert!(!names.contains(&"project.zip".to_string()), "{names:?}");
    assert!(
        !names.iter().any(|name| name.contains(".texlocal-")),
        "{names:?}"
    );
}

#[test]
fn zip_export_excludes_build_and_settings_but_keeps_nested_namesakes() {
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
}

#[test]
fn zip_export_dates_entries_as_their_files_and_leaves_os_litter_out() {
    let data = data_dir();
    let root = project(data.path(), "dated-zip");
    fs::create_dir_all(root.join("figs")).unwrap();
    for litter in [
        ".DS_Store",
        "figs/.DS_Store",
        "figs/Thumbs.db",
        "Desktop.ini",
    ] {
        fs::write(root.join(litter), "x").unwrap();
    }
    fs::write(root.join(".latexmkrc"), "$pdf_mode = 1;").unwrap();
    let dest = data.path().join("out.zip");
    export_zip(&root, &dest).unwrap();

    let names = zip_names(&dest);
    assert!(names.contains(&".latexmkrc".to_string()), "{names:?}");
    for litter in ["DS_Store", "Thumbs.db", "Desktop.ini"] {
        assert!(!names.iter().any(|n| n.contains(litter)), "{names:?}");
    }
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
fn search_is_case_insensitive_for_ascii_and_unicode() {
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
}

#[test]
fn a_hit_carries_the_text_either_side_of_it() {
    let data = data_dir();
    let root = project(data.path(), "snippet");
    fs::write(root.join("a.tex"), "the quick brown fox jumps\n").unwrap();
    let hits = search_project(&root, "brown", 50).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].before, "the quick ");
    assert_eq!(hits[0].matched, "brown");
    assert_eq!(hits[0].after, " fox jumps");
}

#[test]
fn scans_reach_a_nested_build_directory_the_tree_and_zip_both_keep() {
    // Only the project's own top-level build/ is compile output. A `build`
    // deeper in the tree is the author's: file_tree lists it and export_zip
    // archives it, so search and the symbol scan must see it too.
    let data = data_dir();
    let root = project(data.path(), "nested-build");
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
    assert!(scan_symbols(&root)
        .unwrap()
        .labels
        .contains(&"deep:one".to_string()));
}

#[test]
fn top_level_build_output_stays_out_of_every_scan() {
    let data = data_dir();
    let root = project(data.path(), "top-build");
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(root.join("build/main.tex"), "needle \\label{gen:one}\n").unwrap();

    assert!(search_project(&root, "needle", 10).unwrap().is_empty());
    assert!(!scan_symbols(&root)
        .unwrap()
        .labels
        .contains(&"gen:one".to_string()));
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
fn search_stops_at_the_limit_and_skips_build_output() {
    let data = data_dir();
    let root = project(data.path(), "limits");
    fs::write(root.join("many.tex"), "needle\n".repeat(20)).unwrap();
    fs::create_dir_all(root.join("build")).unwrap();
    fs::write(
        root.join("build").join("main.log"),
        "needle in the build dir",
    )
    .unwrap();
    let hits = search_project(&root, "needle", 5).unwrap();
    assert_eq!(hits.len(), 5);
    assert!(hits.iter().all(|h| h.file == "many.tex"));
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
fn unicode_characters_can_match_an_ascii_query() {
    // U+0130 and the Kelvin sign both lowercase into plain ASCII.
    let data = data_dir();
    let root = project(data.path(), "folding");
    fs::write(root.join("a.tex"), "\u{0130}stanbul\n").unwrap();
    fs::write(root.join("b.tex"), "measured 5 \u{212A} today\n").unwrap();

    let hits = search_project(&root, "istanbul", 10).unwrap();
    assert_eq!(
        hits.iter().map(|h| h.file.as_str()).collect::<Vec<_>>(),
        vec!["a.tex"],
        "U+0130 lowercases to an ASCII 'i'"
    );

    let hits = search_project(&root, "k", 10).unwrap();
    assert!(
        hits.iter().any(|h| h.file == "b.tex"),
        "U+212A lowercases to an ASCII 'k': {hits:?}"
    );
}

#[test]
fn a_rename_follows_a_main_file_an_older_build_stored_with_backslashes() {
    // Settings written by an older build can hold "chapters\main.tex". The
    // rename normalises separators before comparing, so it still recognises the
    // file it is moving; without that the main file keeps pointing at the old
    // path and the next compile fails.
    let data = data_dir();
    let root = project(data.path(), "legacy-sep");
    create_file(&root, "chapters/main.tex", false).unwrap();
    fs::write(
        root.join(".texlocal.json"),
        r#"{"mainFile":"chapters\\main.tex","engine":"pdflatex","shellEscape":false}"#,
    )
    .unwrap();

    rename_entry(&root, "chapters", "content").unwrap();

    assert_eq!(read_settings(&root).main_file, "content/main.tex");
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
fn a_new_project_holds_its_template_and_default_settings() {
    let data = data_dir();
    let info = create_project(data.path(), "  Thesis  ", "report").unwrap();
    assert_eq!((info.id.as_str(), info.name.as_str()), ("Thesis", "Thesis"));
    assert_eq!(info.main_file, "main.tex");
    let root = data.path().join("Thesis");
    assert_eq!(
        names_in(&root),
        [".texlocal.json", "main.tex", "references.bib"]
    );
    assert!(fs::read_to_string(root.join("main.tex"))
        .unwrap()
        .contains("{report}"));
}

#[cfg(unix)]
#[test]
fn zip_export_skips_its_own_archive_when_the_destination_is_spelled_through_a_link() {
    // The project is reached through one spelling and the destination through
    // another, as when a Save panel hands back /private/var for a data folder
    // under /var. A lexical comparison would miss that and archive the ZIP's
    // own half-written temporary file into it.
    let data = data_dir();
    let root = project(data.path(), "zip-alias");
    let aliases = tempfile::tempdir().unwrap();
    let alias = aliases.path().join("alias");
    std::os::unix::fs::symlink(&root, &alias).unwrap();
    export_zip(&root, &alias.join("out.zip")).unwrap();
    let names = zip_names(&root.join("out.zip"));
    assert_eq!(names, ["main.tex"]);
}

#[cfg(unix)]
#[test]
fn a_link_loop_in_the_project_is_skipped_rather_than_failing_every_scan() {
    // A link that resolves to nothing, here two links pointing at each other,
    // cannot be shown to stay inside the project, so it is not content. It
    // must not turn the file tree, the scans or the ZIP export into an error.
    let data = data_dir();
    let root = project(data.path(), "link-loop");
    std::os::unix::fs::symlink(root.join("b.tex"), root.join("a.tex")).unwrap();
    std::os::unix::fs::symlink(root.join("a.tex"), root.join("b.tex")).unwrap();

    let names: Vec<String> = file_tree(&root)
        .unwrap()
        .into_iter()
        .map(|n| n.name)
        .collect();
    assert_eq!(names, ["main.tex"]);
    assert!(search_project(&root, "documentclass", 50).is_ok());
    assert!(scan_symbols(&root).is_ok());
    let out = tempfile::tempdir().unwrap();
    export_zip(&root, &out.path().join("out.zip")).unwrap();
    assert_eq!(zip_names(&out.path().join("out.zip")), ["main.tex"]);
}

#[test]
fn citations_include_bibitem_keys_and_commented_or_unfilled_labels_are_left_out() {
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
}
