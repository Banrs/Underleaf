pub mod analyze;
pub mod checks;
pub mod logparse;
pub mod synctex;
pub mod syntax;
pub mod templates;
pub mod wordmatch;

use std::ffi::OsStr;
use std::path::{Component, Path};

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

pub fn file_kind(name: &str) -> &'static str {
    let path = Path::new(name);
    let lower = |part: Option<&OsStr>| part.unwrap_or_default().to_string_lossy().to_lowercase();
    match lower(path.extension()).as_str() {
        "tex" => "tex",
        "bib" => "bib",
        "png" | "jpg" | "jpeg" | "gif" | "svg" | "webp" | "bmp" => "image",
        "pdf" => "pdf",
        ext if TEXT_EXTENSIONS.contains(&ext) => "text",
        "" if TEXT_NAMES.contains(&lower(path.file_name()).as_str()) => "text",
        _ => "other",
    }
}

pub fn is_text(name: &str) -> bool {
    matches!(file_kind(name), "tex" | "bib" | "text")
}

pub(crate) fn utf16_lossy(units: &[u16]) -> String {
    let mut bytes = Vec::with_capacity(units.len());
    let mut rest = units;
    while !rest.is_empty() {
        let ascii = rest.iter().position(|&u| u >= 0x80).unwrap_or(rest.len());
        bytes.extend(rest[..ascii].iter().map(|&u| u as u8));
        rest = &rest[ascii..];
        let other = rest.iter().position(|&u| u < 0x80).unwrap_or(rest.len());
        let mut buf = [0; 4];
        for c in char::decode_utf16(rest[..other].iter().copied()) {
            let c = c.unwrap_or(char::REPLACEMENT_CHARACTER);
            bytes.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
        }
        rest = &rest[other..];
    }
    String::from_utf8(bytes).expect("ASCII and encoded chars are UTF-8")
}
