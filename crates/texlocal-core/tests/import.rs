//! File › Open's import: a folder, a zip or a single file made a new project.

use std::fs;
use std::io::Write;
use std::path::Path;

use texlocal_core::import::import_project;
use texlocal_core::projects::file_tree;
use texlocal_core::service::{Service, UPLOAD_MAX_BYTES};
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
fn a_tex_brings_its_folder_and_is_its_main_file() {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    let src = dir.path().join("Paper");
    for (path, text) in [
        ("main.tex", "\\documentclass{article}"),
        ("paper.tex", "\\documentclass{article}\\input{chapters/a}"),
        ("chapters/a.tex", "\\section{A}"),
        ("refs.bib", "@book{k,}"),
    ] {
        fs::create_dir_all(src.join(path).parent().unwrap()).unwrap();
        fs::write(src.join(path), text).unwrap();
    }
    let info = import_project(&service, &src.join("paper.tex")).unwrap();
    assert_eq!(
        (info.id.as_str(), info.main_file.as_str()),
        ("Paper", "paper.tex")
    );
    assert_eq!(
        names(&service.data_dir.join("Paper")),
        ["chapters/a.tex", "main.tex", "paper.tex", "refs.bib"]
    );

    // Any other file comes alone; without TeX, the blank template's main
    // file joins it.
    let bib = src.join("refs.bib");
    let info = import_project(&service, &bib).unwrap();
    assert_eq!(info.main_file, "main.tex");
    assert_eq!(
        names(&service.data_dir.join("refs")),
        ["main.tex", "refs.bib"]
    );
}

#[test]
fn a_tex_in_a_folder_larger_than_a_project_comes_alone() {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    let downloads = dir.path().join("Downloads");
    fs::create_dir_all(&downloads).unwrap();
    fs::write(downloads.join("notes.tex"), "\\documentclass{article}").unwrap();
    // Sparse: past one upload's bytes without writing them.
    let big = fs::File::create(downloads.join("big.dmg")).unwrap();
    big.set_len(UPLOAD_MAX_BYTES as u64 + 1).unwrap();
    let info = import_project(&service, &downloads.join("notes.tex")).unwrap();
    assert_eq!(
        (info.id.as_str(), info.main_file.as_str()),
        ("notes", "notes.tex")
    );
    assert_eq!(names(&service.data_dir.join("notes")), ["notes.tex"]);

    // As is more than 2000 files.
    fs::remove_file(downloads.join("big.dmg")).unwrap();
    for i in 0..2000 {
        fs::write(downloads.join(format!("{i}.txt")), "").unwrap();
    }
    let info = import_project(&service, &downloads.join("notes.tex")).unwrap();
    assert_eq!(names(&service.data_dir.join(&info.id)), ["notes.tex"]);
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

#[test]
fn excluded_build_output_does_not_count_towards_the_tex_folder_limit() {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    let src = dir.path().join("Paper");
    fs::create_dir_all(src.join("Build")).unwrap();
    fs::write(src.join("main.tex"), "\\input{chapter}").unwrap();
    fs::write(src.join("chapter.tex"), "\\section{Chapter}").unwrap();
    fs::File::create(src.join("Build/main.pdf"))
        .unwrap()
        .set_len(UPLOAD_MAX_BYTES as u64 + 1)
        .unwrap();
    let info = import_project(&service, &src.join("main.tex")).unwrap();
    assert_eq!(
        names(&service.data_dir.join(&info.id)),
        ["chapter.tex", "main.tex"]
    );
}

#[test]
fn a_zip_that_fails_part_way_leaves_no_half_made_project() {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    let src = dir.path().join("broken.zip");
    let mut zip = zip::ZipWriter::new(fs::File::create(&src).unwrap());
    let stored = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    for (path, text) in [("a.tex", "fine"), ("b.tex", "CORRUPTED-LATER")] {
        zip.start_file(path, stored).unwrap();
        zip.write_all(text.as_bytes()).unwrap();
    }
    zip.finish().unwrap();
    // The second file's bytes no longer match its checksum.
    let mut bytes = fs::read(&src).unwrap();
    let at = bytes
        .windows(15)
        .position(|w| w == b"CORRUPTED-LATER")
        .unwrap();
    bytes[at] = b'X';
    fs::write(&src, bytes).unwrap();

    assert!(import_project(&service, &src).is_err());
    assert_eq!(fs::read_dir(&service.data_dir).unwrap().count(), 0);
}

#[test]
fn zip_entries_named_from_the_current_folder_or_with_backslashes_arrive() {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    let dotted = dir.path().join("dotted.zip");
    let windows = dir.path().join("windows.zip");
    for (src, files) in [
        (&dotted, ["./main.tex", "./figs/a.png"]),
        (&windows, ["paper\\main.tex", "paper\\figs\\a.png"]),
    ] {
        let mut zip = zip::ZipWriter::new(fs::File::create(src).unwrap());
        for path in files {
            zip.start_file(path, SimpleFileOptions::default()).unwrap();
            zip.write_all(b"\\documentclass{article}").unwrap();
        }
        zip.finish().unwrap();
        let info = import_project(&service, src).unwrap();
        assert_eq!(info.main_file, "main.tex");
        let root = service.data_dir.join(&info.id);
        assert_eq!(names(&root), ["figs/a.png", "main.tex"]);
    }
}
