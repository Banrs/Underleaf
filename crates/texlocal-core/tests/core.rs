//! Port of test/projects.test.js — the same nine cases, same error messages
//! (they surface in the UI), plus coverage the JS suite lacked: separator
//! normalization and ZIP export exclusions.

use std::fs;
use std::path::Path;

use serde_json::json;
use tempfile::TempDir;
use texlocal_core::logparse::parse_log;
use texlocal_core::paths::{project_root, safe_path, safe_rel_file};
use texlocal_core::projects::{
    create_file, create_project, delete_entry, rename_entry, search_project,
};
use texlocal_core::settings::{compiled_pdf_path, read_settings, write_settings};
use texlocal_core::zipexport::export_zip;

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

#[test]
fn settings_reject_unsafe_compiler_inputs() {
    let data = data_dir();
    let root = project(data.path(), "settings-test");

    let err = write_settings(&root, &json!({ "shellEscape": "false" })).unwrap_err();
    assert!(
        err.message.contains("shellEscape must be a boolean"),
        "{}",
        err.message
    );

    let err = write_settings(&root, &json!({ "mainFile": "-interaction.tex" })).unwrap_err();
    assert!(
        err.message.contains("Path segments cannot start"),
        "{}",
        err.message
    );

    let err = write_settings(&root, &json!({ "mainFile": "../outside.tex" })).unwrap_err();
    assert!(
        err.message.contains("Path escapes project"),
        "{}",
        err.message
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
fn deleting_an_entry_removes_it_whether_or_not_a_trash_is_available() {
    let data = data_dir();
    let root = project(data.path(), "discard-test");
    create_file(&root, "notes/scratch.tex", false).unwrap();
    assert!(root.join("notes/scratch.tex").exists());

    delete_entry(&root, "notes/scratch.tex").unwrap();

    // The entry is gone from the project either way: a temp dir usually has no
    // trash directory on its filesystem, so this exercises the fallback.
    assert!(!root.join("notes/scratch.tex").exists());
    assert!(root.join("notes").exists(), "only the file was asked for");
}

#[test]
fn the_active_main_file_and_its_parent_cannot_be_deleted() {
    let data = data_dir();
    let root = project(data.path(), "delete-test");
    create_file(&root, "chapters/main.tex", false).unwrap();
    write_settings(&root, &json!({ "mainFile": "chapters/main.tex" })).unwrap();

    let err = delete_entry(&root, "chapters/main.tex").unwrap_err();
    assert!(
        err.message.contains("different main file"),
        "{}",
        err.message
    );
    let err = delete_entry(&root, "chapters").unwrap_err();
    assert!(
        err.message.contains("different main file"),
        "{}",
        err.message
    );

    let raw: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(root.join(".texlocal.json")).unwrap()).unwrap();
    assert_eq!(raw["mainFile"], "chapters/main.tex");
}

#[test]
fn path_traversal_is_rejected_at_every_boundary() {
    let data = data_dir();
    let root = project(data.path(), "paths-test");

    assert!(project_root(data.path(), "../etc")
        .unwrap_err()
        .message
        .contains("Bad project id"));
    assert!(safe_path(&root, "../x")
        .unwrap_err()
        .message
        .contains("Path escapes project"));
    assert!(safe_path(&root, "a/../../b")
        .unwrap_err()
        .message
        .contains("Path escapes project"));
    assert!(safe_path(&root, ".")
        .unwrap_err()
        .message
        .contains("Path escapes project"));
    assert!(safe_path(&root, "")
        .unwrap_err()
        .message
        .contains("Missing path"));
    // Windows-style traversal must not slip through on any platform.
    assert!(safe_path(&root, r"..\x")
        .unwrap_err()
        .message
        .contains("Path escapes project"));
    assert!(safe_path(&root, r"C:\x")
        .unwrap_err()
        .message
        .contains("Path escapes project"));
}

#[test]
fn the_settings_file_is_not_reachable_through_the_file_api() {
    let data = data_dir();
    let root = project(data.path(), "reserved-test");

    assert!(safe_path(&root, ".texlocal.json")
        .unwrap_err()
        .message
        .contains("Reserved file"));
    // Nested files of the same name are ordinary files.
    assert!(safe_path(&root, "sub/.texlocal.json").is_ok());
}

#[test]
fn project_names_are_sanitized() {
    let data = data_dir();
    assert!(create_project(data.path(), ".hidden", "blank")
        .unwrap_err()
        .message
        .contains("Invalid name"));
    assert!(create_project(data.path(), "   ", "blank")
        .unwrap_err()
        .message
        .contains("Invalid name"));
    create_project(data.path(), "dup-test", "blank").unwrap();
    assert!(create_project(data.path(), "dup-test", "blank")
        .unwrap_err()
        .message
        .contains("already exists"));
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

    // "chapters" is a prefix of "chapters2" as a string but not as a path.
    rename_entry(&root, "chapters", "content").unwrap();
    assert_eq!(read_settings(&root).main_file, "chapters2/other.tex");
}

#[test]
fn parse_log_extracts_errors_warnings_and_deduplicates_reruns() {
    let log = [
        "./main.tex:12: Undefined control sequence.",
        "l.12 \\badcommand",
        "",
        "! Emergency stop.",
        "l.40 \\end{document}",
        "",
        "LaTeX Warning: Reference `fig:x' on page 1 undefined",
        "on input line 10.",
        "",
        "./main.tex:12: Undefined control sequence.",
        "l.12 \\badcommand",
    ]
    .join("\n");

    let items = parse_log(&log, "main.tex");
    let errors: Vec<_> = items.iter().filter(|i| i.kind == "error").collect();
    let warnings: Vec<_> = items.iter().filter(|i| i.kind == "warning").collect();

    assert_eq!(errors.len(), 2, "duplicate file:line error should collapse");
    assert_eq!(errors[0].file.as_deref(), Some("main.tex"));
    assert_eq!(errors[0].line, Some(12));
    assert_eq!(errors[1].message, "Emergency stop.");
    assert_eq!(errors[1].line, Some(40));
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0].line, Some(10));
    assert!(warnings[0].message.contains("fig:x"));
}

#[test]
fn a_backslash_main_file_from_an_old_settings_file_still_works() {
    let data = data_dir();
    let root = project(data.path(), "backslash-test");
    create_file(&root, "chapters/paper.tex", false).unwrap();
    // Hand-write the settings file the way a Windows browser-mode session
    // would have: backslash separators.
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

/// `zip -r` followed symlinks and archived the target's content. A symlinked
/// references.bib or figures directory is a normal thing for a project to
/// contain, so dropping them would hand the user an archive that no longer
/// compiles.
#[cfg(unix)]
#[test]
fn zip_export_follows_symlinks_the_way_the_zip_cli_did() {
    let data = data_dir();
    let root = project(data.path(), "symlink-test");
    fs::write(root.join("real.tex"), "shared").unwrap();
    std::os::unix::fs::symlink(root.join("real.tex"), root.join("linked.tex")).unwrap();
    // A dangling link has no target to archive; it must be skipped, not fatal.
    std::os::unix::fs::symlink(root.join("gone.tex"), root.join("broken.tex")).unwrap();

    let dest = data.path().join("out.zip");
    export_zip(&root, &dest).unwrap();

    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let names: Vec<String> = (0..archive.len())
        .map(|i| archive.by_index(i).unwrap().name().to_string())
        .collect();
    assert!(
        names.contains(&"linked.tex".to_string()),
        "symlink dropped: {names:?}"
    );
    assert!(
        !names.contains(&"broken.tex".to_string()),
        "dangling link kept: {names:?}"
    );

    let mut linked = archive.by_name("linked.tex").unwrap();
    let mut body = String::new();
    std::io::Read::read_to_string(&mut linked, &mut body).unwrap();
    assert_eq!(
        body, "shared",
        "symlink archived without its target's content"
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

    let mut archive = zip::ZipArchive::new(fs::File::open(&dest).unwrap()).unwrap();
    let names: Vec<String> = (0..archive.len())
        .map(|i| archive.by_index(i).unwrap().name().to_string())
        .collect();

    assert!(names.contains(&"main.tex".to_string()), "{names:?}");
    assert!(
        names.contains(&"chapters/intro.tex".to_string()),
        "{names:?}"
    );
    assert!(
        names.contains(&"sub/.texlocal.json".to_string()),
        "nested namesake kept: {names:?}"
    );
    assert!(
        !names.iter().any(|n| n.starts_with("build")),
        "build/ excluded: {names:?}"
    );
    assert!(
        !names.contains(&".texlocal.json".to_string()),
        "settings excluded: {names:?}"
    );
}

// search_project had no coverage at all, and its inner loop folds case by hand:
// an ASCII branch for the bulk of a .tex file and `to_lowercase` for the rest.
// These pin both branches, and the snippet arithmetic around a hit.

#[test]
fn search_is_case_insensitive_in_both_folding_branches() {
    let data = data_dir();
    let root = project(data.path(), "search");
    fs::write(root.join("ascii.tex"), "One\nThe THEOREM holds\n").unwrap();
    // Non-ASCII: the fold has to go through `to_lowercase`, not the byte path.
    fs::write(root.join("accents.tex"), "L'ÉCOLE Normale\nStraße\n").unwrap();

    let hits = search_project(&root, "theorem", 50).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].file, "ascii.tex");
    assert_eq!(hits[0].line, 2);
    assert_eq!(hits[0].matched, "THEOREM");

    let hits = search_project(&root, "école", 50).unwrap();
    assert_eq!(hits.len(), 1, "uppercase É must be found by lowercase é");
    assert_eq!(hits[0].matched, "ÉCOLE");

    // A query that shares no first character with anything must find nothing —
    // the case a fast reject would be most likely to get wrong.
    assert!(search_project(&root, "zzz", 50).unwrap().is_empty());
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
    assert_eq!(hits.len(), 5, "the limit is honoured");
    assert!(
        hits.iter().all(|h| h.file == "many.tex"),
        "build output is never searched"
    );
}
