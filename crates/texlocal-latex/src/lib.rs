pub mod analyze;
pub mod checks;
pub mod diff;
pub mod logparse;
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

const TEXT_EXTENSIONS: &[&str] = &[
    "ltx", "cls", "sty", "clo", "def", "cfg", "bst", "bbx", "cbx", "lbx", "dtx", "ins", "ist",
    "lco", "tikz", "pgf", "mf", "mp", "asy", "rnw", "rmd", "qmd", "md", "txt", "csv", "tsv", "dat",
    "json", "yaml", "yml", "toml", "ini", "xml", "lua", "py", "r", "sh",
];

const TEXT_NAMES: &[&str] = &["latexmkrc", "makefile", "license", "readme"];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum FileKind {
    Tex,
    Bib,
    Image,
    Pdf,
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
        ext if TEXT_EXTENSIONS.contains(&ext) => FileKind::Text,
        "" if TEXT_NAMES.contains(&lower(path.file_name()).as_str()) => FileKind::Text,
        _ => FileKind::Other,
    }
}

pub fn is_text(name: &str) -> bool {
    matches!(
        file_kind(name),
        FileKind::Tex | FileKind::Bib | FileKind::Text
    )
}
