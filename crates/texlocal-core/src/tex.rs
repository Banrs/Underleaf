//! Finding TeX: the PATH a GUI app's thin environment lacks, the programs on
//! it, and whether latexmk runs.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::process::run;
use crate::settings::AppSettings;
use crate::tinytex;

fn children(dir: impl AsRef<Path>) -> impl Iterator<Item = PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
}

/// TeX Live's year folders' programs, newest first.
fn texlive_bins() -> impl Iterator<Item = PathBuf> {
    let root = if cfg!(windows) {
        let mut root = std::env::var_os("SystemDrive").unwrap_or_else(|| "C:".into());
        root.push(r"\texlive");
        PathBuf::from(root)
    } else {
        PathBuf::from("/usr/local/texlive")
    };
    let mut years: Vec<_> = children(root)
        .filter(|year| {
            year.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.len() == 4 && name.bytes().all(|b| b.is_ascii_digit()))
        })
        .map(|year| year.join("bin"))
        .collect();
    years.sort_unstable_by(|a, b| b.cmp(a));
    years.into_iter().flat_map(children)
}

/// The PATHs for TeX's tools and for TeXpresso's: the chosen TeX folder, the user's PATH, then discovered TeX dirs. Built per use, so an install made while the app runs is found.
pub(crate) fn tool_paths(app: &AppSettings) -> (String, String) {
    let user = std::env::var_os("PATH").unwrap_or_default();
    let tex: Vec<PathBuf> = (app.tex_dir.iter().cloned())
        .chain(absolute_dirs(&user))
        .chain(usual_tex_dirs())
        .chain(texlive_bins())
        .collect();
    let texpresso = join_path(app.texpresso_dir.iter().chain(&tex).cloned());
    (join_path(tex), texpresso)
}

/// Where TeX's installers put its programs, besides TeX Live's years: MacTeX's
/// link and Homebrew's folders, or MiKTeX's for one user and for all; then TinyTeX's.
fn usual_tex_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = if cfg!(windows) {
        let under = |var, dir| Some(PathBuf::from(std::env::var_os(var)?).join(dir));
        [
            under("LOCALAPPDATA", r"Programs\MiKTeX\miktex\bin\x64"),
            under("ProgramFiles", r"MiKTeX\miktex\bin\x64"),
        ]
        .into_iter()
        .flatten()
        .collect()
    } else {
        ["/Library/TeX/texbin", "/usr/local/bin", "/opt/homebrew/bin"]
            .map(PathBuf::from)
            .into()
    };
    dirs.extend(tinytex::root().map(|root| tinytex::bin(&root)));
    dirs
}

/// Folders as a PATH, in the platform's form. A folder whose name holds the
/// separator can't be one of them, and is left out.
pub(crate) fn join_path(dirs: impl IntoIterator<Item = PathBuf>) -> String {
    let dirs = dirs
        .into_iter()
        .filter(|dir| std::env::join_paths([dir]).is_ok());
    std::env::join_paths(dirs)
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// A PATH's absolute folders: an empty or relative entry would be looked up
/// from the project, where a latexmk of its own could stand.
fn absolute_dirs(path: &std::ffi::OsStr) -> impl Iterator<Item = PathBuf> + '_ {
    std::env::split_paths(path).filter(|dir| dir.is_absolute())
}

pub(crate) fn find_tool(program: &str, path_env: &str) -> Option<PathBuf> {
    which::which_in(program, Some(path_env), Path::new("/")).ok()
}

pub(crate) fn program_at(path: &Path) -> Option<PathBuf> {
    path.is_absolute().then(|| which::which(path).ok())?
}

/// The TeX programs folder `dir` names: `dir` itself, or the bin folder of a
/// TeX Live root picked in its place.
pub(crate) fn tex_bin_dir(dir: &Path) -> Option<PathBuf> {
    std::iter::once(dir.to_path_buf())
        .chain(children(dir.join("bin")))
        .find(|c| program_at(&c.join("latexmk")).is_some())
}

static LATEXMK_VERSION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"Version (\d[\w.]*)").unwrap());

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TexStatus {
    pub available: bool,
    pub latexmk_version: Option<String>,
    pub tex_dir: Option<String>,
    pub found: Option<String>,
    pub texpresso: Option<String>,
    pub texpresso_dir: Option<String>,
}

pub async fn tex_available(path_env: &str) -> TexStatus {
    let Ok((0, stdout)) = run("latexmk", &["-version"], None, path_env).await else {
        return TexStatus::default();
    };
    TexStatus {
        available: true,
        latexmk_version: LATEXMK_VERSION
            .captures(&stdout)
            .map(|found| found[1].to_owned()),
        found: find_tool("latexmk", path_env)
            .and_then(|latexmk| Some(latexmk.parent()?.to_string_lossy().into_owned())),
        ..TexStatus::default()
    }
}

#[cfg(test)]
mod tests {
    use super::absolute_dirs;
    use std::path::Path;

    #[test]
    fn tools_are_found_only_in_absolute_folders_of_the_path() {
        let base = std::env::temp_dir();
        let (first, last) = (base.join("bin"), base.join("tex").join("bin"));
        let path = std::env::join_paths([&first, Path::new(""), Path::new("."), &last]).unwrap();
        let dirs: Vec<_> = absolute_dirs(&path).collect();
        assert_eq!(dirs, [first, last]);
    }
}
