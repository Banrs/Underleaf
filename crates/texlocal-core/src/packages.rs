//! Installing the TeX Live package that holds a file LaTeX didn't find, with TeX Live's
//! tlmgr, as an administrator through the system's own dialog where only one may change
//! TeX Live (MacTeX's tree, or one installed on Windows for all users).

use std::path::Path;
use std::process::Stdio;
use std::sync::LazyLock;
use std::time::Duration;

use regex::Regex;
use tokio::process::Command;

use crate::error::CoreError;
use crate::process::{self, Tree, drive};
use crate::tex::find_tool;

/// tlmgr downloads the repository's catalogue, then the package and what it depends on.
const TIMEOUT: Duration = Duration::from_secs(600);
/// What tlmgr and the names it is given may be: no option, path or shell syntax.
static NAME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9_.][A-Za-z0-9_.-]*$").unwrap());
// tlmgr's own words, which it doesn't translate, for the failures a person can put right.
static UNREACHABLE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"could not get texlive\.tlpdb|Cannot load TeX Live database|download(?:ing)? did not succeed|cannot contact")
        .unwrap()
});
const OLDER: &str = "is older than remote repository";
const NOT_WRITABLE: &str = "don't have permission to change the installation";

/// The names come as arguments, never as script, and `quoted form` makes each one word to the
/// shell. The dialog names the app and the package where it would name osascript.
#[cfg(not(windows))]
const AS_ADMINISTRATOR: &str = r#"on run {tlmgr, package}
do shell script quoted form of tlmgr & " install " & quoted form of package with prompt "TeXLocal wants to install the TeX package “" & package & "”." with administrator privileges
end run"#;
/// The names come in the environment, never as script. The elevated tlmgr's output can't be
/// read, only its exit code; 1223 is Windows' ERROR_CANCELLED.
#[cfg(windows)]
const AS_ADMINISTRATOR: &str = "try { $p = Start-Process -FilePath $env:TEXLOCAL_TLMGR \
    -ArgumentList install, $env:TEXLOCAL_PACKAGE -Verb RunAs -WindowStyle Hidden -Wait \
    -PassThru -ErrorAction Stop } catch { exit 1223 }; exit $p.ExitCode";

/// Installs the package that holds `file` (“foo.sty”), and answers its name.
pub(crate) async fn install_package(file: &str, path_env: &str) -> Result<String, CoreError> {
    if !NAME.is_match(file) {
        return Err(CoreError::bad_request(format!(
            "“{file}” isn't a file's name."
        )));
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
        .ok_or_else(|| CoreError::not_found(format!("No TeX Live package has “{file}”.")))?;
    let mut installed = run_tlmgr(&["install", &package]).await?;
    if installed.0 != 0 && installed.1.contains(NOT_WRITABLE) {
        installed = run(as_administrator(&tlmgr, &package, path_env)?).await?;
        // AppleScript's error -128, or Windows' ERROR_CANCELLED.
        let cancelled = if cfg!(windows) {
            installed.0 == 1223
        } else {
            installed.1.contains("(-128)")
        };
        if cancelled {
            let message = format!("Installing “{package}” was cancelled.");
            return Err(CoreError::new(403, message));
        }
    }
    checked(installed)?;
    Ok(package)
}

/// The package with a file at `/<file>`: tlmgr reads it as a pattern, which also matches
/// minted-sty-hooks.4ht for minted.sty. Of several, the shortest path is the release's own
/// (latex's fixltx2e.sty, not latex-base-dev's).
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

#[cfg(not(windows))]
fn as_administrator(tlmgr: &Path, package: &str, path_env: &str) -> Result<Command, CoreError> {
    let mut command = process::command("osascript", None, path_env)?;
    command
        .args(["-e", AS_ADMINISTRATOR])
        .arg(tlmgr)
        .arg(package);
    Ok(command)
}

#[cfg(windows)]
fn as_administrator(tlmgr: &Path, package: &str, path_env: &str) -> Result<Command, CoreError> {
    let mut command = process::command("powershell", None, path_env)?;
    command
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            AS_ADMINISTRATOR,
        ])
        .env("TEXLOCAL_TLMGR", tlmgr)
        .env("TEXLOCAL_PACKAGE", package);
    Ok(command)
}

/// The exit code and everything printed, stderr after stdout.
pub(crate) async fn run(mut command: Command) -> Result<(i32, String), CoreError> {
    let (mut child, tree) = Tree::spawn(command.stdin(Stdio::null()))?;
    let (code, mut out, err, timed_out) = drive(&mut child, &tree, TIMEOUT).await;
    if timed_out {
        return Err(CoreError::new(
            504,
            "Installing took over ten minutes, and was stopped.",
        ));
    }
    out.push_str(&err);
    Ok((code, out))
}

pub(crate) fn checked((code, out): (i32, String)) -> Result<String, CoreError> {
    if code == 0 {
        Ok(out)
    } else if out.contains(OLDER) {
        Err(CoreError::conflict(
            "This TeX Live is older than the release its repository serves, and tlmgr adds packages only to that release. Update TeX Live first: tug.org/texlive/upgrade.html",
        ))
    } else if UNREACHABLE.is_match(&out) {
        Err(CoreError::new(
            503,
            "TeX Live's package repository can't be reached. Check the internet connection, then try again.",
        ))
    } else {
        Err(CoreError::internal(format!(
            "TeX Live's package manager failed:\n{}",
            crate::tail(out.trim(), 2000)
        )))
    }
}

fn no_tlmgr(path_env: &str) -> CoreError {
    CoreError::new(
        501,
        if find_tool("mpm", path_env).is_some() {
            "MiKTeX installs missing packages itself as it compiles: in MiKTeX Console's Settings, choose to always install missing packages on-the-fly, then compile again."
        } else {
            "TeX Live's package manager, tlmgr, wasn't found with TeX."
        },
    )
}

#[cfg(all(test, unix))]
mod tests;
