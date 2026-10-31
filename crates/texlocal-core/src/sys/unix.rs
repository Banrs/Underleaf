use std::ffi::OsString;
use std::fs::{self, Metadata, Permissions};
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::process::{Child, Command};

use crate::process;

pub(crate) const TEXLIVE: &str = "/usr/local/texlive";

pub(crate) struct Group(u32);

pub(crate) fn latexmkrc(var: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    let dir = |key| var(key).map(PathBuf::from).filter(|p| p.is_absolute());
    let home = dir("HOME")?;
    let config = dir("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config"));
    [config.join("latexmk/latexmkrc"), home.join(".latexmkrc")]
        .into_iter()
        .find(|rc| rc.is_file())
}

pub(crate) fn download(url: &str, to: &Path, path_env: &str) -> Command {
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

pub(crate) fn unpack(archive: &Path, into: &Path, path_env: &str) -> Command {
    let mut command = process::tool(Path::new("/usr/bin/tar"), path_env);
    command.arg("-xf").arg(archive).arg("-C").arg(into);
    command
}

pub(crate) fn default_permissions(builder: &mut tempfile::Builder) {
    builder.permissions(Permissions::from_mode(0o666));
}

pub(crate) fn private(builder: &mut tempfile::Builder) {
    builder.permissions(Permissions::from_mode(0o700));
}

pub(crate) fn identity(_: &Path, meta: &Metadata) -> io::Result<(u64, u64)> {
    Ok((meta.dev(), meta.ino()))
}

fn executable(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|meta| meta.is_file() && meta.mode() & 0o111 != 0)
}

pub(crate) fn program(dir: &Path, name: &str) -> Option<PathBuf> {
    Some(dir.join(name)).filter(|path| executable(path))
}

pub(crate) fn spawn_group(command: &mut Command) -> io::Result<(Child, Group)> {
    let child = command.process_group(0).spawn()?;
    let leader = child.id().expect("a child just spawned has its pid");
    Ok((child, Group(leader)))
}

pub(crate) fn kill_group(group: &Group) {
    unsafe {
        libc::killpg(group.0 as i32, libc::SIGKILL);
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
    use std::os::unix::process::ExitStatusExt;

    use super::*;

    #[tokio::test]
    async fn a_child_starts_with_the_signals_the_app_ignores_back_at_their_defaults() {
        let ignored = unsafe { libc::signal(libc::SIGUSR1, libc::SIG_IGN) };
        let mut command = process::command("sh", None, "/bin").unwrap();
        let ran = command.args(["-c", "kill -USR1 $$"]).status().await;
        unsafe { libc::signal(libc::SIGUSR1, ignored) };
        assert_eq!(ran.unwrap().signal(), Some(libc::SIGUSR1));
    }

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
