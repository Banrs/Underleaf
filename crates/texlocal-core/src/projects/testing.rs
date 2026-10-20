//! What the unit tests of projects, import and export set up alike.

use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use super::{create_project, file_tree};
use crate::CoreError;
use crate::service::Service;

#[track_caller]
pub(crate) fn fails_with<T: std::fmt::Debug>(result: Result<T, CoreError>, text: &str) {
    let message = result.unwrap_err().message;
    assert!(message.contains(text), "{message:?} lacks {text:?}");
}

pub(crate) fn library() -> (TempDir, Service) {
    let dir = tempfile::tempdir().unwrap();
    let service = Service::new(dir.path().join("data"));
    fs::create_dir_all(&service.data_dir).unwrap();
    (dir, service)
}

pub(crate) fn with_project() -> (TempDir, Service) {
    let (dir, service) = library();
    create_project(&service.data_dir, "P", "blank", None).unwrap();
    (dir, service)
}

pub(crate) fn project() -> (TempDir, PathBuf) {
    let (dir, service) = with_project();
    let root = service.project_root("P").unwrap();
    (dir, root)
}

pub(crate) fn names_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

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

pub(crate) fn zip_names(path: &Path) -> Vec<String> {
    let archive = zip::ZipArchive::new(File::open(path).unwrap()).unwrap();
    archive.file_names().map(str::to_owned).collect()
}
