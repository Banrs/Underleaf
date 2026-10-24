//! Installing TinyTeX, a small TeX Live the user owns, where TinyTeX's own installers put it:
//! no password is asked for, and R's tinytex and TeX's other tools find it there too.

use std::path::{Path, PathBuf};

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::error::CoreError;
use crate::packages::{checked, run};
use crate::process;
use crate::tex::{find_tool, join_path};

const RELEASE: &str = "https://api.github.com/repos/rstudio/tinytex-releases/releases/latest";
/// TinyTeX-1 has pdfLaTeX, XeTeX (Live Preview's), latexmk and the templates' packages but
/// beamer; TinyTeX-0 has no LaTeX, and the bundle without a number is three times the size.
const BUNDLE: (&str, &str) = ("TinyTeX-1-darwin-", ".tar.xz");
/// The Presentation template's class, and programs builds run that Install can't add, as it
/// adds only the package of a file LaTeX didn't find.
const PACKAGES: [&str; 2] = ["beamer", "makeindex"];
/// An install's folder until it is complete, beside where it goes: a quit leaves it, and the
/// next install removes it.
const UNFINISHED: &str = ".texlocal-tinytex-";

/// Where TinyTeX's installer puts it.
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
    // One at a time, so that none removes another's unfinished folder.
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
    // The release is up to a month old, and its tlmgr may be older than the repository wants.
    tlmgr(&unpacked, path_env, &["update", "--self"]).await?;
    let install = ["install"].into_iter().chain(PACKAGES);
    tlmgr(&unpacked, path_env, &install.collect::<Vec<_>>()).await?;
    std::fs::rename(&unpacked, root)?;
    // XeTeX's font configuration names TeX's font folders, only now where they stay.
    let postaction = ["postaction", "install", "script", "xetex"];
    tlmgr(root, path_env, &postaction).await
}

/// Downloads the latest release's bundle into `temp`, checks it, and unpacks it there.
async fn unpack(temp: &Path, path_env: &str) -> Result<PathBuf, CoreError> {
    let release = temp.join("release.json");
    fetch(RELEASE, &release, path_env).await?;
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

/// This computer's bundle, and the SHA-256 GitHub gives it.
fn bundle(release: &Release) -> Option<(&str, &str)> {
    let (start, end) = BUNDLE;
    let asset =
        (release.assets.iter()).find(|a| a.name.starts_with(start) && a.name.ends_with(end))?;
    let digest = asset.digest.as_deref()?.strip_prefix("sha256:")?;
    Some((&asset.browser_download_url, digest))
}

/// `url` saved at `to` by the system's curl.
async fn fetch(url: &str, to: &Path, path_env: &str) -> Result<(), CoreError> {
    let mut command = process::command("curl", None, path_env)?;
    // A stalled download fails after a minute, not at the ten minutes `run` allows.
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
        // curl's codes for a host it couldn't resolve or connect to, and for its time limits.
        (6 | 7, _) => Err(CoreError::new(
            503,
            "GitHub, where TinyTeX comes from, can't be reached. Check the internet connection, then try again.",
        )),
        (28, _) => Err(CoreError::new(
            504,
            "TinyTeX's download stalled, and was stopped. Try again later.",
        )),
        (_, out) => Err(CoreError::internal(format!(
            "TinyTeX couldn't be downloaded:\n{}",
            crate::tail(out.trim(), 2000)
        ))),
    }
}

/// TinyTeX's tlmgr at `root`, its programs first on the PATH.
async fn tlmgr(root: &Path, path_env: &str, args: &[&str]) -> Result<(), CoreError> {
    let path = join_path(std::iter::once(bin(root)).chain(std::env::split_paths(path_env)));
    let tlmgr = find_tool("tlmgr", &path)
        .ok_or_else(|| CoreError::internal("TinyTeX's package manager, tlmgr, wasn't found."))?;
    let mut command = process::tool(&tlmgr, &path);
    command.args(args);
    checked(run(command).await?).map(drop)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_computer_s_tinytex_1_is_chosen_with_its_sha_256() {
        let release = |digest: Option<&str>| -> Release {
            let assets = [
                "TinyTeX-0-darwin-v1.tar.xz",
                "TinyTeX-darwin-v1.tar.xz",
                "TinyTeX-1-darwin-v1.tar.xz",
                "TinyTeX-0-windows-v1.exe",
                "TinyTeX-windows-v1.exe",
                "TinyTeX-1-windows-v1.exe",
                "TinyTeX-1-tar-v1.gz",
            ]
            .map(|name| {
                let url = format!("https://x/{name}");
                let digest = digest.map(|sum| format!("sha256:{sum}"));
                serde_json::json!({ "name": name, "browser_download_url": url, "digest": digest })
            });
            serde_json::from_value(serde_json::json!({ "assets": assets })).unwrap()
        };
        let mine = "https://x/TinyTeX-1-darwin-v1.tar.xz";
        assert_eq!(bundle(&release(Some("ab12"))), Some((mine, "ab12")));
        // Without a sum to check it by, none is taken.
        assert_eq!(bundle(&release(None)), None);
    }

    #[tokio::test]
    async fn an_install_leaves_a_tinytex_there_alone_and_a_failed_one_leaves_nothing() {
        let home = tempfile::tempdir().unwrap();
        let root = home.path().join("TinyTeX");
        std::fs::create_dir(&root).unwrap();
        let err = install_into(&root, "").await.unwrap_err();
        assert_eq!(err.status, 409, "{}", err.message);
        assert!(root.exists());

        // An unfinished folder a quit left goes; without curl, this install fails at once.
        std::fs::remove_dir(&root).unwrap();
        std::fs::create_dir(home.path().join(format!("{UNFINISHED}quit"))).unwrap();
        assert_eq!(install_into(&root, "").await.unwrap_err().status, 404);
        assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
    }

    /// Downloads TinyTeX into a temporary folder and builds every template with it, and the
    /// article with XeTeX: `cargo test -p texlocal-core tinytex -- --ignored --nocapture`.
    #[tokio::test]
    #[ignore = "downloads TinyTeX"]
    async fn tinytex_installs_and_builds_every_template() {
        let home = tempfile::tempdir().unwrap();
        let root = home.path().join("TinyTeX");
        let user = std::env::var("PATH").unwrap();
        let started = std::time::Instant::now();
        install_into(&root, &user).await.unwrap();
        eprintln!("installed in {:?}", started.elapsed());
        assert_eq!(crate::tex::tex_bin_dir(&root), Some(bin(&root)));
        let path = join_path(std::iter::once(bin(&root)).chain(std::env::split_paths(&user)));
        assert!(find_tool("makeindex", &path).unwrap().starts_with(&root));

        let (_dir, service) = crate::projects::testing::library();
        let builds = crate::templates::TEMPLATES
            .map(|template| (template, None))
            .into_iter()
            .chain([("article", Some("xelatex"))]);
        for (n, (template, engine)) in builds.enumerate() {
            let name = format!("{n} {template}");
            crate::projects::create_project(&service.data_dir, &name, template, engine).unwrap();
            let project = service.project(&name).unwrap();
            let result = service
                .compile
                .compile(&project, &path, false)
                .await
                .unwrap();
            assert!(result.ok, "{name}: {}", result.log);
        }
    }
}
