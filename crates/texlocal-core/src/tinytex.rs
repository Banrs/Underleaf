use std::path::Path;

use serde::Deserialize;

use crate::error::CoreError;
use crate::messages;
use crate::packages::{checked, run};
use crate::process::Processes;
use crate::tex::{find_tool, join_path};
use crate::{process, sys};

const RELEASE: &str = "https://api.github.com/repos/rstudio/tinytex-releases/releases/latest";
const UNFINISHED: &str = ".texlocal-tinytex-";

pub(crate) async fn install(processes: &Processes, path_env: &str) -> Result<(), CoreError> {
    let root = sys::tinytex_root().ok_or_else(|| CoreError::internal(messages::no_home()))?;
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
    match run(processes, None, sys::unpack(&archive, temp, path_env)).await? {
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
    let (start, end) = sys::TINYTEX_BUNDLE;
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
    match run(processes, None, sys::download(url, to, path_env)).await? {
        (0, _) => Ok(()),
        (6 | 7, _) => Err(CoreError::unavailable(messages::github_unreachable())),
        (28, _) => Err(CoreError::unavailable(messages::tinytex_stalled())),
        (_, out) => Err(CoreError::internal(messages::tinytex_download_failed(
            crate::tail(out.trim(), 2000),
        ))),
    }
}

async fn tlmgr(
    processes: &Processes,
    root: &Path,
    path_env: &str,
    args: &[&str],
) -> Result<(), CoreError> {
    let path =
        join_path(std::iter::once(sys::tinytex_bin(root)).chain(std::env::split_paths(path_env)));
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
