use std::path::{Path, PathBuf};

use serde::Deserialize;
use tokio::process::Command;

use crate::error::CoreError;
use crate::messages;
use crate::packages::{checked, run};
use crate::process;
use crate::process::Processes;
use crate::tex::{find_tool, join_path};

const RELEASE: &str = "https://api.github.com/repos/rstudio/tinytex-releases/releases/latest";
const UNFINISHED: &str = ".texlocal-tinytex-";
const BUNDLE: (&str, &str) = ("TinyTeX-1-darwin-", ".tar.xz");

pub(crate) fn root() -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("HOME")?).join("Library/TinyTeX"))
}

pub(crate) fn bin(root: &Path) -> PathBuf {
    root.join("bin/universal-darwin")
}

pub(crate) async fn install(processes: &Processes, path_env: &str) -> Result<(), CoreError> {
    let root = root().ok_or_else(|| CoreError::internal(messages::no_home()))?;
    install_into(processes, &root, path_env).await
}

async fn install_into(processes: &Processes, root: &Path, path_env: &str) -> Result<(), CoreError> {
    static INSTALLING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _one = INSTALLING.lock().await;
    if root.exists() {
        return Err(CoreError::conflict(messages::tinytex_there(root.display())));
    }
    let parent = root.parent().expect("TinyTeX's folder is in another");
    std::fs::create_dir_all(parent)?;
    for entry in std::fs::read_dir(parent)?.filter_map(Result::ok) {
        if entry.file_name().to_string_lossy().starts_with(UNFINISHED) {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
    let temp = tempfile::Builder::new()
        .prefix(UNFINISHED)
        .tempdir_in(parent)?;
    unpack(processes, temp.path(), path_env).await?;
    let name = root.file_name().expect("TinyTeX's folder has a name");
    let unpacked = temp.path().join(name);
    tlmgr(processes, &unpacked, path_env, &["update", "--self"]).await?;
    let packages = ["install", "beamer", "makeindex"];
    tlmgr(processes, &unpacked, path_env, &packages).await?;
    std::fs::rename(&unpacked, root)?;
    let postaction = ["postaction", "install", "script", "xetex"];
    let done = tlmgr(processes, root, path_env, &postaction).await;
    if done.is_err() {
        let _ = std::fs::rename(root, &unpacked);
    }
    done
}

async fn unpack(processes: &Processes, temp: &Path, path_env: &str) -> Result<(), CoreError> {
    let release = temp.join("release.json");
    fetch(processes, RELEASE, &release, path_env).await?;
    let release = serde_json::from_slice(&std::fs::read(&release)?)
        .map_err(|err| CoreError::internal(messages::unexpected(err)))?;
    let (url, digest) =
        bundle(&release).ok_or_else(|| CoreError::internal(messages::no_tinytex_bundle()))?;
    let archive = temp.join("TinyTeX.tar.xz");
    fetch(processes, url, &archive, path_env).await?;
    if crate::sha256(&std::fs::read(&archive)?) != digest {
        return Err(CoreError::internal(messages::tinytex_mismatch()));
    }
    match run(processes, None, untar(&archive, temp, path_env)).await? {
        (0, _) => Ok(()),
        (_, out) => Err(CoreError::internal(messages::tinytex_unpack_failed(
            crate::tail(out.trim(), 2000),
        ))),
    }
}

#[derive(Deserialize)]
struct Release {
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
    digest: Option<String>,
}

fn bundle(release: &Release) -> Option<(&str, &str)> {
    let (start, end) = BUNDLE;
    let asset =
        (release.assets.iter()).find(|a| a.name.starts_with(start) && a.name.ends_with(end))?;
    let digest = asset.digest.as_deref()?.strip_prefix("sha256:")?;
    Some((&asset.browser_download_url, digest))
}

async fn fetch(
    processes: &Processes,
    url: &str,
    to: &Path,
    path_env: &str,
) -> Result<(), CoreError> {
    let download = download(url, to, path_env);
    match process::run(processes, None, download, None).await? {
        (0, ..) => Ok(()),
        (6 | 7, ..) => Err(CoreError::unavailable(messages::github_unreachable())),
        (28, ..) => Err(CoreError::unavailable(messages::tinytex_stalled())),
        (_, out, _) => Err(CoreError::internal(messages::tinytex_download_failed(
            crate::tail(out.trim(), 2000),
        ))),
    }
}

fn download(url: &str, to: &Path, path_env: &str) -> Command {
    let mut command = process::tool(Path::new("/usr/bin/curl"), path_env);
    command
        .args(["--fail", "--location", "--silent", "--show-error"])
        .args([
            "--connect-timeout",
            "30",
            "--speed-limit",
            "1000",
            "--speed-time",
            "60",
        ])
        .arg("--output")
        .arg(to)
        .arg(url);
    command
}

fn untar(archive: &Path, into: &Path, path_env: &str) -> Command {
    let mut command = process::tool(Path::new("/usr/bin/tar"), path_env);
    command.arg("-xf").arg(archive).arg("-C").arg(into);
    command
}

async fn tlmgr(
    processes: &Processes,
    root: &Path,
    path_env: &str,
    args: &[&str],
) -> Result<(), CoreError> {
    let path = join_path(std::iter::once(bin(root)).chain(std::env::split_paths(path_env)));
    let tlmgr = find_tool("tlmgr", &path)
        .ok_or_else(|| CoreError::internal(messages::no_tinytex_tlmgr()))?;
    let mut command = process::tool(&tlmgr, &path);
    command.args(args);
    checked(run(processes, None, command).await?).map(drop)
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn tinytex_is_not_installed_over_a_folder_already_there() {
        let root = tempfile::tempdir().unwrap();
        let processes = super::Processes::default();
        let refused = super::install_into(&processes, root.path(), "")
            .await
            .unwrap_err();
        assert_eq!(refused.kind, crate::ErrorKind::Conflict);
        assert!(root.path().is_dir());
    }
}
