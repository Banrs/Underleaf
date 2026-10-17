//! Finding TeX: the PATH a GUI app's thin environment lacks, the programs on
//! it, and whether latexmk runs.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::process::{PROBE_TIMEOUT, run};
use crate::settings::AppSettings;

/// What `dir` holds; nothing if it can't be read.
fn children(dir: impl AsRef<Path>) -> impl Iterator<Item = PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
}

fn texlive_root() -> PathBuf {
    if cfg!(windows) {
        let mut root = std::env::var_os("SystemDrive").unwrap_or_else(|| "C:".into());
        root.push(r"\texlive");
        root.into()
    } else {
        PathBuf::from("/usr/local/texlive")
    }
}

/// Year/architecture-specific TeX Live bin dirs, newest year first.
fn texlive_bins() -> impl Iterator<Item = PathBuf> {
    let mut years: Vec<_> = children(texlive_root())
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

/// The PATHs for TeX's tools, and for TeXpresso's: the TeX folder chosen
/// first, then the user's PATH, then the discovered TeX dirs; TeXpresso's
/// with its own folder before all of them. Built per use — a couple of
/// read_dirs — so a TeX install performed while the app runs is found without
/// a restart.
pub(crate) fn tool_paths(app: &AppSettings) -> (String, String) {
    let user = std::env::var_os("PATH").unwrap_or_default();
    let tex: Vec<PathBuf> = (app.tex_dir.iter().cloned())
        .chain(absolute_dirs(&user))
        .chain(usual_tex_dirs())
        .chain(texlive_bins())
        .collect();
    let texpresso = app.texpresso_dir.iter().chain(&tex).cloned();
    (join_path(tex.clone()), join_path(texpresso))
}

/// Where TeX's installers put its programs, besides TeX Live's years: MacTeX's
/// link and Homebrew's folders, or MiKTeX's for one user and for all.
fn usual_tex_dirs() -> Vec<PathBuf> {
    if cfg!(windows) {
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
    }
}

/// Folders as a PATH, in the platform's form. A folder whose name holds the
/// separator can't be one of them, and is left out.
fn join_path(dirs: impl IntoIterator<Item = PathBuf>) -> String {
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

/// `program` as a shell finds it in `path_env`'s folders: a file it may run,
/// by any of Windows' program extensions (.exe, .bat …) there.
pub(crate) fn find_tool(program: &str, path_env: &str) -> Option<PathBuf> {
    // The PATHs built here hold absolute folders only: none is found from
    // the folder given for relative ones.
    which::which_in(program, Some(path_env), Path::new("/")).ok()
}

/// The program at the absolute `path`, by any of Windows' program extensions.
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

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TexStatus {
    pub available: bool,
    pub version: Option<String>,
    /// The TeX folder the user chose; None finds TeX automatically.
    pub tex_dir: Option<String>,
    /// The folder the working latexmk runs from.
    pub found: Option<String>,
    /// The TeXpresso program live preview would run, and the folder chosen for it.
    pub texpresso: Option<String>,
    pub texpresso_dir: Option<String>,
}

pub async fn tex_available(path_env: &str) -> TexStatus {
    let probe = run("latexmk", &["-version"], None, PROBE_TIMEOUT, path_env).await;
    let (available, stdout) = match probe {
        Ok((0, stdout)) => (true, stdout),
        _ => (false, String::new()),
    };
    TexStatus {
        available,
        version: available.then(|| version_line(&stdout)),
        found: available
            .then(|| find_tool("latexmk", path_env))
            .flatten()
            .and_then(|latexmk| Some(latexmk.parent()?.to_string_lossy().into_owned())),
        ..TexStatus::default()
    }
}

/// latexmk's own version line, falling back to the first nonempty line.
fn version_line(stdout: &str) -> String {
    let mut lines = stdout.lines().map(str::trim).filter(|l| !l.is_empty());
    let first = lines.clone().next().unwrap_or("");
    lines
        .find(|l| l.starts_with("Latexmk"))
        .unwrap_or(first)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::{absolute_dirs, version_line};
    use std::path::Path;

    #[test]
    fn tools_are_found_only_in_absolute_folders_of_the_path() {
        let base = std::env::temp_dir();
        let (first, last) = (base.join("bin"), base.join("tex").join("bin"));
        let path = std::env::join_paths([&first, Path::new(""), Path::new("."), &last]).unwrap();
        let dirs: Vec<_> = absolute_dirs(&path).collect();
        assert_eq!(dirs, [first, last]);
    }

    #[test]
    fn the_version_names_latexmk() {
        assert_eq!(
            version_line("Latexmk, John Collins, 1 Jan 2025. Version 4.86\n"),
            "Latexmk, John Collins, 1 Jan 2025. Version 4.86"
        );
        assert_eq!(version_line("something else\n"), "something else");
    }
}
