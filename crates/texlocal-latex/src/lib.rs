pub mod bib;
pub mod cite;
pub mod diff;
pub mod facts;
pub mod logparse;
pub mod message;
pub mod messages;
pub mod project;
pub mod protocol;
pub mod search;
pub mod synctex;
pub mod syntax;
pub mod templates;
pub mod utf16;
pub mod wordmatch;

use std::ffi::OsStr;
use std::path::{Component, Path};

use schemars::JsonSchema;
use serde::Serialize;

pub fn segments(rel: &str) -> Option<Vec<&str>> {
    let mut segments = Vec::new();
    for component in Path::new(rel).components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                segments.pop()?;
            }
            Component::Normal(segment) => segments.push(segment.to_str()?),
            _ => return None,
        }
    }
    Some(segments)
}

pub fn fold_case(path: &str) -> String {
    path.to_uppercase().to_lowercase()
}

/// Whether two paths are the same once case-folded, comparing ASCII ones without allocating.
pub fn same_folded(a: &str, b: &str) -> bool {
    if a.is_ascii() && b.is_ascii() {
        a.eq_ignore_ascii_case(b)
    } else {
        fold_case(a) == fold_case(b)
    }
}

/// Classes, packages and the files they load or are built from.
const PACKAGE_EXTENSIONS: &[&str] = &[
    "cls", "sty", "clo", "def", "cfg", "bst", "bbx", "cbx", "lbx", "dtx", "ins", "ist", "lco",
];

const TEXT_EXTENSIONS: &[&str] = &[
    "ltx", "tikz", "pgf", "mf", "mp", "asy", "rnw", "rmd", "qmd", "md", "txt", "csv", "tsv", "dat",
    "json", "yaml", "yml", "toml", "ini", "xml", "lua", "py", "r", "sh",
];

const TEXT_NAMES: &[&str] = &["latexmkrc", "makefile", "license", "readme"];

#[derive(PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum FileKind {
    Tex,
    Bib,
    Image,
    Pdf,
    Package,
    Text,
    Other,
}

pub fn file_kind(name: &str) -> FileKind {
    let path = Path::new(name);
    let lower = |part: Option<&OsStr>| fold_case(&part.unwrap_or_default().to_string_lossy());
    match lower(path.extension()).as_str() {
        "tex" => FileKind::Tex,
        "bib" => FileKind::Bib,
        "png" | "jpg" | "jpeg" | "gif" | "svg" | "webp" | "bmp" => FileKind::Image,
        "pdf" => FileKind::Pdf,
        ext if PACKAGE_EXTENSIONS.contains(&ext) => FileKind::Package,
        ext if TEXT_EXTENSIONS.contains(&ext) => FileKind::Text,
        "" if TEXT_NAMES.contains(&lower(path.file_name()).as_str()) => FileKind::Text,
        _ => FileKind::Other,
    }
}

pub fn is_text(name: &str) -> bool {
    matches!(
        file_kind(name),
        FileKind::Tex | FileKind::Bib | FileKind::Package | FileKind::Text
    )
}
