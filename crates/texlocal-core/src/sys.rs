//! What the core asks of the operating system. What every Unix answers alike is here; what each answers its own
//! way is in a module per system, which a port adds beside these.

use std::ffi::OsString;
use std::fs::{Metadata, Permissions};
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::process::{Child, Command};

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "linux")]
pub(crate) use linux::{copy_xattrs, flush, put_back, rename_exclusive, trash};
#[cfg(target_os = "macos")]
pub(crate) use macos::{copy_xattrs, flush, put_back, rename_exclusive, trash};

pub(crate) struct Group(u32);

pub(crate) fn latexmkrc(var: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    let dir = |key| var(key).map(PathBuf::from).filter(|p| p.is_absolute());
    let home = dir("HOME")?;
    let config = dir("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config"));
    [config.join("latexmk/latexmkrc"), home.join(".latexmkrc")]
        .into_iter()
        .find(|rc| rc.is_file())
}

pub(crate) fn private(builder: &mut tempfile::Builder) {
    builder.permissions(Permissions::from_mode(0o700));
}

// A new file's usual mode, narrowed by the umask, where tempfile would make it private.
pub(crate) fn ordinary(builder: &mut tempfile::Builder) {
    builder.permissions(Permissions::from_mode(0o666));
}

pub(crate) fn is_executable(meta: &Metadata) -> bool {
    meta.mode() & 0o111 != 0
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

pub(crate) fn identity(meta: &Metadata) -> (u64, u64) {
    (meta.dev(), meta.ino())
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

#[cfg(test)]
mod tests {
    use std::os::unix::process::ExitStatusExt;
    use std::path::Path;

    use super::*;
    use crate::process;

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
