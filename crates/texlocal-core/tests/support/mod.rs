//! Stand-in programs, for the suites that run TeX's tools.
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

/// A stand-in program `name` in `dir` that runs the shell `script`, which
/// may be given again to change it. Its path.
///
/// A program rewritten can fail to start with ETXTBSY: a child that another
/// test's thread forked meanwhile holds the file open for writing until it
/// execs. So the program is a wrapper, written once and run once to be sure
/// it starts, that hands over to the script, which sh only reads.
#[cfg(unix)]
pub fn program(dir: &Path, name: &str, script: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, Instant};
    fs::create_dir_all(dir).unwrap();
    let put = |path: &Path, text: &str, mode| {
        let temp = dir.join(format!(".{name}.new"));
        fs::write(&temp, text).unwrap();
        fs::set_permissions(&temp, fs::Permissions::from_mode(mode)).unwrap();
        fs::rename(&temp, path).unwrap();
    };
    let exe = dir.join(name);
    put(&dir.join(format!("{name}.sh")), script, 0o644);
    if !exe.exists() {
        let wrapper =
            "#!/bin/sh\n[ -n \"$STUB_PROBE\" ] && exit 0\nexec /bin/sh \"$0.sh\" \"$@\"\n";
        put(&exe, wrapper, 0o755);
        let until = Instant::now() + Duration::from_secs(5);
        let mut probe = std::process::Command::new(&exe);
        while let Err(err) = probe.env("STUB_PROBE", "1").status() {
            let busy = err.raw_os_error() == Some(libc::ETXTBSY);
            assert!(busy && Instant::now() < until, "{name}: {err}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    exe
}

/// A stand-in program `name` in `dir` that prints `line`: a shell script, or
/// a batch file on Windows. Its path.
pub fn echoing(dir: &Path, name: &str, line: &str) -> PathBuf {
    #[cfg(unix)]
    return program(dir, name, &format!("echo '{line}'\n"));
    #[cfg(windows)]
    {
        fs::create_dir_all(dir).unwrap();
        let exe = dir.join(format!("{name}.bat"));
        fs::write(&exe, format!("@echo {line}\r\n")).unwrap();
        exe
    }
}
