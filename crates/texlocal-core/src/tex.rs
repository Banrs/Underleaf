use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};

use regex::Regex;
use serde::Serialize;
use texlocal_latex::syntax::Installed;

use crate::process::run;
use crate::settings::AppSettings;
use crate::stamp::Kept;
use crate::sys;

fn children(dir: impl AsRef<Path>) -> impl Iterator<Item = PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
}

fn texlive_bins() -> impl Iterator<Item = PathBuf> {
    let mut years: Vec<_> = children(sys::TEXLIVE)
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

fn usual_tex_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = sys::TEX_DIRS.map(PathBuf::from).into();
    dirs.extend(sys::tinytex_root().map(|root| sys::tinytex_bin(&root)));
    dirs
}

pub(crate) fn join_path(dirs: impl IntoIterator<Item = PathBuf>) -> String {
    let dirs = dirs
        .into_iter()
        .filter(|dir| std::env::join_paths([dir]).is_ok());
    std::env::join_paths(dirs)
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn absolute_dirs(path: &OsStr) -> impl Iterator<Item = PathBuf> + '_ {
    std::env::split_paths(path).filter(|dir| dir.is_absolute())
}

pub(crate) fn find_tool(program: &str, path_env: &str) -> Option<PathBuf> {
    absolute_dirs(OsStr::new(path_env))
        .map(|dir| dir.join(program))
        .find(|path| executable(path))
}

pub(crate) fn program_at(path: &Path) -> Option<PathBuf> {
    (path.is_absolute() && executable(path)).then(|| path.to_path_buf())
}

fn executable(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|meta| sys::executable(&meta))
}

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

pub(crate) fn installed(path_env: &str) -> Arc<Installed> {
    static READ: Kept<Installed> = Kept::new();
    let ls_r = find_tool("latexmk", path_env).and_then(|latexmk| ls_r_above(&latexmk));
    let installed = ls_r.and_then(|ls_r| READ.get(&ls_r, read_installed).ok());
    installed.unwrap_or_default()
}

fn ls_r_above(program: &Path) -> Option<PathBuf> {
    let program = std::fs::canonicalize(program).unwrap_or_else(|_| program.to_path_buf());
    let mut found = program
        .ancestors()
        .map(|dir| dir.join("texmf-dist").join("ls-R"));
    found.find(|ls_r| ls_r.is_file())
}

fn read_installed(ls_r: &Path) -> std::io::Result<Installed> {
    Ok(Installed::from_ls_r(&crate::lossy_string(std::fs::read(
        ls_r,
    )?)))
}
