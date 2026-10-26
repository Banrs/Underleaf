use std::path::{Path, PathBuf};

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::error::CoreError;
use crate::packages::{checked, run};
use crate::process;
use crate::tex::{find_tool, join_path};

const RELEASE: &str = "https://api.github.com/repos/rstudio/tinytex-releases/releases/latest";
const BUNDLE: (&str, &str) = ("TinyTeX-1-darwin-", ".tar.xz");
const PACKAGES: [&str; 2] = ["beamer", "makeindex"];
const UNFINISHED: &str = ".texlocal-tinytex-";

pub(crate) fn root() -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("HOME")?).join("Library/TinyTeX"))
}

pub(crate) fn bin(root: &Path) -> PathBuf {
    root.join("bin/universal-darwin")
}

pub(crate) async fn install(path_env: &str) -> Result<(), CoreError> {
    let root = root().ok_or_else(|| CoreError::internal("The user's folder isn't known."))?;
    install_into(&root, path_env).await
}

async fn install_into(root: &Path, path_env: &str) -> Result<(), CoreError> {
    static INSTALLING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _one = INSTALLING.lock().await;
    if root.exists() {
        let message = format!(
            "“{}” is there already, and was left as it is.",
            root.display()
        );
        return Err(CoreError::conflict(message));
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
    let unpacked = unpack(temp.path(), path_env).await?;
    tlmgr(&unpacked, path_env, &["update", "--self"]).await?;
    let install = ["install"].into_iter().chain(PACKAGES);
    tlmgr(&unpacked, path_env, &install.collect::<Vec<_>>()).await?;
    std::fs::rename(&unpacked, root)?;
    let postaction = ["postaction", "install", "script", "xetex"];
    tlmgr(root, path_env, &postaction).await
}

async fn unpack(temp: &Path, path_env: &str) -> Result<PathBuf, CoreError> {
    let release = temp.join("release.json");
    let asked = std::env::var("TEXLOCAL_TINYTEX_RELEASE").unwrap_or_else(|_| RELEASE.into());
    fetch(&asked, &release, path_env).await?;
    let release = serde_json::from_slice(&std::fs::read(&release)?)
        .map_err(|err| CoreError::internal(err.to_string()))?;
    let (url, digest) = bundle(&release).ok_or_else(|| {
        CoreError::internal("TinyTeX's latest release has no bundle for this computer.")
    })?;
    let archive = temp.join("TinyTeX.tar.xz");
    fetch(url, &archive, path_env).await?;
    let sum = Sha256::digest(std::fs::read(&archive)?);
    if sum.iter().map(|b| format!("{b:02x}")).collect::<String>() != digest {
        return Err(CoreError::internal(
            "TinyTeX's download wasn't what GitHub says it is. Try again.",
        ));
    }
    let mut command = process::command("tar", None, path_env)?;
    command.arg("-xf").arg(&archive).arg("-C").arg(temp);
    match run(command).await? {
        (0, _) => Ok(temp.join("TinyTeX")),
        (_, out) => Err(CoreError::internal(format!(
            "TinyTeX couldn't be unpacked:\n{}",
            crate::tail(out.trim(), 2000)
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

async fn fetch(url: &str, to: &Path, path_env: &str) -> Result<(), CoreError> {
    let mut command = process::command("curl", None, path_env)?;
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
    match run(command).await? {
        (0, _) => Ok(()),
        (6 | 7, _) => Err(CoreError::new(
            crate::ErrorKind::Unavailable,
            "GitHub, where TinyTeX comes from, can't be reached. Check the internet connection, then try again.",
        )),
        (28, _) => Err(CoreError::new(
            crate::ErrorKind::Unavailable,
            "TinyTeX's download stalled, and was stopped. Try again later.",
        )),
        (_, out) => Err(CoreError::internal(format!(
            "TinyTeX couldn't be downloaded:\n{}",
            crate::tail(out.trim(), 2000)
        ))),
    }
}

async fn tlmgr(root: &Path, path_env: &str, args: &[&str]) -> Result<(), CoreError> {
    let path = join_path(std::iter::once(bin(root)).chain(std::env::split_paths(path_env)));
    let tlmgr = find_tool("tlmgr", &path)
        .ok_or_else(|| CoreError::internal("TinyTeX's package manager, tlmgr, wasn't found."))?;
    let mut command = process::tool(&tlmgr, &path);
    command.args(args);
    checked(run(command).await?).map(drop)
}
