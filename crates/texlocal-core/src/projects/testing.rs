//! What the unit tests of projects, import and export set up alike.

use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use super::{create_project, file_tree};
use crate::service::Service;

/// An empty library, and the service over it.
pub(crate) fn library() -> (TempDir, Service) {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    fs::create_dir_all(&service.data_dir).unwrap();
    (dir, service)
}

/// A library with one blank project, "P".
pub(crate) fn with_project() -> (TempDir, Service) {
    let (dir, service) = library();
    create_project(&service.data_dir, "P", "blank", None).unwrap();
    (dir, service)
}

/// A library with one blank project, "P", and the project's folder.
pub(crate) fn project() -> (TempDir, PathBuf) {
    let (dir, service) = with_project();
    let root = service.project_root("P").unwrap();
    (dir, root)
}

/// What a folder holds, by name.
pub(crate) fn names_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// A project's files as its tree shows them, by path.
pub(crate) fn files_in(root: &Path) -> Vec<String> {
    fn walk(nodes: Vec<super::TreeNode>, out: &mut Vec<String>) {
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

/// A zip of `files`, deflated as most are.
pub(crate) fn zip_of(path: &Path, files: &[(&str, &str)]) {
    zip_with(path, files, zip::CompressionMethod::Deflated);
}

/// A zip of `files` written with `method`: stored, a test can find and change
/// their bytes.
pub(crate) fn zip_with(path: &Path, files: &[(&str, &str)], method: zip::CompressionMethod) {
    let mut zip = zip::ZipWriter::new(File::create(path).unwrap());
    let options = zip::write::SimpleFileOptions::default().compression_method(method);
    for (name, text) in files {
        zip.start_file(*name, options).unwrap();
        zip.write_all(text.as_bytes()).unwrap();
    }
    zip.finish().unwrap();
}

/// The names of a zip's entries, in order.
pub(crate) fn zip_names(path: &Path) -> Vec<String> {
    let archive = zip::ZipArchive::new(File::open(path).unwrap()).unwrap();
    archive.file_names().map(str::to_owned).collect()
}
