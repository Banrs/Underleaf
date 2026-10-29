use std::sync::LazyLock;
use std::time::Duration;

use regex::Regex;
use tokio::process::Command;

use crate::error::CoreError;
use crate::messages;
use crate::process::{self, Tree, drive};
use crate::sys;
use crate::tex::find_tool;

const TIMEOUT: Duration = Duration::from_secs(600);
static NAME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9_.][A-Za-z0-9_.-]*$").unwrap());
static UNREACHABLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"could not get texlive\.tlpdb|Cannot load TeX Live database|download(?:ing)? did not succeed|cannot contact")
        .unwrap()
});
const OLDER: &str = "is older than remote repository";
const NOT_WRITABLE: &str = "don't have permission to change the installation";

pub(crate) async fn install_package(file: &str, path_env: &str) -> Result<String, CoreError> {
    if !NAME.is_match(file) {
        return Err(CoreError::bad_request(messages::not_a_file_name(file)));
    }
    let tlmgr = find_tool("tlmgr", path_env).ok_or_else(|| no_tlmgr(path_env))?;
    let run_tlmgr = |args: &[&str]| {
        let mut command = process::tool(&tlmgr, path_env);
        command.args(args);
        run(command)
    };
    let pattern = format!("/{file}");
    let found = checked(run_tlmgr(&["search", "--global", "--file", &pattern]).await?)?;
    let package = holder(&found, &pattern)
        .ok_or_else(|| CoreError::not_found(messages::no_package_has(file)))?;
    let mut installed = run_tlmgr(&["install", &package]).await?;
    if installed.0 != 0 && installed.1.contains(NOT_WRITABLE) {
        installed = run(sys::install_as_administrator(&tlmgr, &package, path_env)).await?;
        if installed.1.contains(sys::ADMIN_CANCELLED) {
            let message = messages::install_cancelled(&package);
            return Err(CoreError::new(crate::ErrorKind::Denied, message));
        }
    }
    checked(installed)?;
    Ok(package)
}

fn holder(found: &str, slashed: &str) -> Option<String> {
    let mut package = "";
    found
        .lines()
        .filter_map(|line| match line.strip_prefix('\t') {
            Some(path) => Some((path, package)),
            None => {
                package = line.strip_suffix(':').unwrap_or_default();
                None
            }
        })
        .filter(|(path, package)| path.ends_with(slashed) && NAME.is_match(package))
        .min_by_key(|(path, _)| path.len())
        .map(|(_, package)| package.to_owned())
}

pub(crate) async fn run(mut command: Command) -> Result<(i32, String), CoreError> {
    let (mut child, tree) = Tree::spawn(&mut command)?;
    match drive(&mut child, &tree, Some(TIMEOUT)).await {
        (.., true) => Err(CoreError::unavailable(messages::install_timed_out())),
        (code, out, false) => Ok((code, out)),
    }
}

pub(crate) fn checked((code, out): (i32, String)) -> Result<String, CoreError> {
    if code == 0 {
        Ok(out)
    } else if out.contains(OLDER) {
        Err(CoreError::conflict(messages::texlive_older()))
    } else if UNREACHABLE.is_match(&out) {
        Err(CoreError::unavailable(messages::repository_unreachable()))
    } else {
        let said = crate::tail(out.trim(), 2000);
        Err(CoreError::internal(messages::tlmgr_failed(said)))
    }
}

fn no_tlmgr(path_env: &str) -> CoreError {
    CoreError::unavailable(if find_tool("mpm", path_env).is_some() {
        messages::miktex_installs()
    } else {
        messages::no_tlmgr()
    })
}
