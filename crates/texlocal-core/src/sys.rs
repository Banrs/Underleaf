use std::ffi::{CString, OsString};
use std::fs::{File, Metadata, Permissions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::process::{Child, Command};

use crate::error::CoreError;
use crate::messages;
use crate::process;

pub(crate) const TEXLIVE: &str = "/usr/local/texlive";
pub(crate) const TEX_DIRS: [&str; 3] =
    ["/Library/TeX/texbin", "/usr/local/bin", "/opt/homebrew/bin"];
pub(crate) const TINYTEX_BUNDLE: (&str, &str) = ("TinyTeX-1-darwin-", ".tar.xz");
pub(crate) const ADMIN_CANCELLED: &str = "(-128)";

const AS_ADMINISTRATOR: &str = r#"on run {tlmgr, package}
do shell script quoted form of tlmgr & " install " & quoted form of package with prompt "TeXLocal wants to install the TeX package “" & package & "”." with administrator privileges
end run"#;

pub(crate) fn tinytex_root() -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("HOME")?).join("Library/TinyTeX"))
}

pub(crate) fn tinytex_bin(root: &Path) -> PathBuf {
    root.join("bin/universal-darwin")
}

pub(crate) fn latexmkrc(var: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    let dir = |key| var(key).map(PathBuf::from).filter(|p| p.is_absolute());
    let home = dir("HOME")?;
    let config = dir("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config"));
    [config.join("latexmk/latexmkrc"), home.join(".latexmkrc")]
        .into_iter()
        .find(|rc| rc.is_file())
}

pub(crate) fn trash(path: &Path) -> Result<(), CoreError> {
    let trashed = std::process::Command::new("/usr/bin/trash")
        .arg("-s")
        .arg(path)
        .output()?;
    if trashed.status.success() {
        return Ok(());
    }
    let said = String::from_utf8_lossy(&trashed.stderr);
    Err(CoreError::internal(messages::trash_failed(said.trim())))
}

pub(crate) fn install_as_administrator(
    tlmgr: &Path,
    package: &str,
    path_env: &str,
) -> io::Result<Command> {
    let mut command = process::command("osascript", None, path_env)?;
    command
        .args(["-e", AS_ADMINISTRATOR])
        .arg(tlmgr)
        .arg(package);
    Ok(command)
}

pub(crate) fn download(url: &str, to: &Path, path_env: &str) -> io::Result<Command> {
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
    Ok(command)
}

pub(crate) fn unpack(archive: &Path, into: &Path, path_env: &str) -> io::Result<Command> {
    let mut command = process::command("tar", None, path_env)?;
    command.arg("-xf").arg(archive).arg("-C").arg(into);
    Ok(command)
}

pub(crate) fn permissions(mode: u32) -> Permissions {
    Permissions::from_mode(mode)
}

pub(crate) fn identity(meta: &Metadata) -> (u64, u64) {
    (meta.dev(), meta.ino())
}

pub(crate) fn executable(meta: &Metadata) -> bool {
    meta.is_file() && meta.mode() & 0o111 != 0
}

pub(crate) fn copy_xattrs(from: &Path, to: &File) {
    if let Ok(from) = File::open(from) {
        unsafe {
            libc::fcopyfile(
                from.as_raw_fd(),
                to.as_raw_fd(),
                std::ptr::null_mut(),
                libc::COPYFILE_XATTR,
            );
        }
    }
}

pub(crate) fn rename_exclusive(from: &Path, to: &Path) -> io::Result<()> {
    let from = CString::new(from.as_os_str().as_encoded_bytes())?;
    let to = CString::new(to.as_os_str().as_encoded_bytes())?;
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

pub(crate) fn spawn_group(command: &mut Command) -> io::Result<(Child, u32)> {
    let child = command.process_group(0).spawn()?;
    let group = child.id().expect("a child just spawned has its pid");
    Ok((child, group))
}

pub(crate) fn kill_group(group: u32) {
    unsafe {
        libc::killpg(group as i32, libc::SIGKILL);
    }
}

pub(crate) fn wait_exited(pid: u32) {
    unsafe {
        let mut info: libc::siginfo_t = std::mem::zeroed();
        let flags = libc::WEXITED | libc::WNOWAIT;
        while libc::waitid(libc::P_PID, pid as libc::id_t, &raw mut info, flags) == -1
            && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted
        {}
    }
}

pub(crate) fn default_signals(command: &mut Command) {
    unsafe {
        command.pre_exec(|| {
            for signal in 1..32 {
                libc::signal(signal, libc::SIG_DFL);
            }
            let mut none: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&raw mut none);
            libc::sigprocmask(libc::SIG_SETMASK, &raw const none, std::ptr::null_mut());
            Ok(())
        });
    }
}

pub(crate) fn local_time(time: SystemTime) -> Option<(u16, u8, u8, u8, u8, u8)> {
    let secs = time.duration_since(UNIX_EPOCH).ok()?.as_secs();
    let secs = libc::time_t::try_from(secs).ok()?;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&raw const secs, &raw mut tm) }.is_null() {
        return None;
    }
    let field = |value: libc::c_int| u8::try_from(value).ok();
    let year = u16::try_from(tm.tm_year + 1900).ok()?;
    let (month, day) = (field(tm.tm_mon + 1)?, field(tm.tm_mday)?);
    let (hour, minute, second) = (field(tm.tm_hour)?, field(tm.tm_min)?, field(tm.tm_sec)?);
    Some((year, month, day, hour, minute, second))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn latexmkrc_is_found_in_the_config_folder_then_home() {
        let (home, xdg) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let found = |vars: &[(&str, &Path)]| {
            latexmkrc(|key| vars.iter().find(|(k, _)| *k == key).map(|(_, v)| v.into()))
        };
        let home_only = [("HOME", home.path())];
        assert_eq!(found(&home_only), None);
        std::fs::write(home.path().join(".latexmkrc"), "").unwrap();
        assert_eq!(found(&home_only), Some(home.path().join(".latexmkrc")));
        let config = home.path().join(".config/latexmk");
        std::fs::create_dir_all(&config).unwrap();
        std::fs::write(config.join("latexmkrc"), "").unwrap();
        assert_eq!(found(&home_only), Some(config.join("latexmkrc")));
        let elsewhere = [("HOME", home.path()), ("XDG_CONFIG_HOME", xdg.path())];
        assert_eq!(found(&elsewhere), Some(home.path().join(".latexmkrc")));
        assert_eq!(found(&[("HOME", Path::new("relative"))]), None);
        assert_eq!(found(&[]), None);
    }
}
