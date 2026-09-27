//! File › Open's import: a folder, a zip or a single file made a new project.

use std::fs;
use std::io::Write;
use std::path::Path;

use texlocal_core::import::import_project;
use texlocal_core::projects::file_tree;
use texlocal_core::service::Service;
use zip::write::SimpleFileOptions;

fn names(root: &Path) -> Vec<String> {
    fn walk(nodes: Vec<texlocal_core::projects::TreeNode>, out: &mut Vec<String>) {
        for node in nodes {
            match node.children {
                Some(children) => walk(children, out),
                None => out.push(node.path),
            }
        }
    }
    let mut out = Vec::new();
    walk(file_tree(root).unwrap(), &mut out);
    out.sort();
    out
}

#[test]
fn a_folder_brings_its_visible_files_and_its_name() {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    let src = dir.path().join("Thesis");
    for (path, text) in [
        ("main.tex", "\\documentclass{book}"),
        ("figs/a.png", "png"),
        ("figs/.DS_Store", "x"),
        (".git/HEAD", "ref"),
        ("build/main.pdf", "old output"),
    ] {
        fs::create_dir_all(src.join(path).parent().unwrap()).unwrap();
        fs::write(src.join(path), text).unwrap();
    }

    let info = import_project(&service, &src).unwrap();
    assert_eq!(
        (info.id.as_str(), info.main_file.as_str()),
        ("Thesis", "main.tex")
    );
    let root = service.data_dir.join("Thesis");
    assert_eq!(names(&root), ["figs/a.png", "main.tex"]);
    assert!(!root.join(".git").exists() && !root.join("build").exists());

    // A taken name gets a number, as Finder's copies do.
    assert_eq!(import_project(&service, &src).unwrap().id, "Thesis 2");
}

#[test]
fn a_zip_of_one_folder_brings_that_folders_contents() {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    let src = dir.path().join("paper.zip");
    let mut zip = zip::ZipWriter::new(fs::File::create(&src).unwrap());
    for (path, text) in [
        ("paper/aaa.tex", "\\section{Intro}"),
        ("paper/doc.tex", "\\documentclass{article}"),
        ("paper/figs/b.png", "png"),
        ("__MACOSX/paper/._doc.tex", "fork"),
    ] {
        zip.start_file(path, SimpleFileOptions::default()).unwrap();
        zip.write_all(text.as_bytes()).unwrap();
    }
    zip.finish().unwrap();

    let info = import_project(&service, &src).unwrap();
    // No main.tex: the first file that starts a document.
    assert_eq!(
        (info.id.as_str(), info.main_file.as_str()),
        ("paper", "doc.tex")
    );
    let root = service.data_dir.join("paper");
    assert_eq!(names(&root), ["aaa.tex", "doc.tex", "figs/b.png"]);
    assert_eq!(fs::read_to_string(root.join("figs/b.png")).unwrap(), "png");
}

#[test]
fn a_single_file_is_the_project_and_its_main_file_if_it_is_tex() {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    let tex = dir.path().join("notes.tex");
    fs::write(&tex, "\\documentclass{article}").unwrap();
    let info = import_project(&service, &tex).unwrap();
    assert_eq!(
        (info.id.as_str(), info.main_file.as_str()),
        ("notes", "notes.tex")
    );

    // Without TeX, the blank template's main file joins it.
    let bib = dir.path().join("refs.bib");
    fs::write(&bib, "@book{k,}").unwrap();
    let info = import_project(&service, &bib).unwrap();
    assert_eq!(info.main_file, "main.tex");
    assert_eq!(
        names(&service.data_dir.join("refs")),
        ["main.tex", "refs.bib"]
    );
}

#[cfg(unix)]
#[test]
fn a_failed_import_leaves_no_half_made_project() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    let src = dir.path().join("Locked");
    fs::create_dir_all(&src).unwrap();
    fs::write(src.join("a.tex"), "fine").unwrap();
    fs::write(src.join("b.tex"), "unreadable").unwrap();
    fs::set_permissions(src.join("b.tex"), fs::Permissions::from_mode(0o000)).unwrap();
    assert!(import_project(&service, &src).is_err());
    assert_eq!(fs::read_dir(&service.data_dir).unwrap().count(), 0);
}
