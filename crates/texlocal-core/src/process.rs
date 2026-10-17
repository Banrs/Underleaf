//! Running TeX's tools: a command with the augmented PATH, the whole tree of
//! processes it starts killed together, and output kept to a cap while the
//! child runs.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use tokio::io::AsyncReadExt;

use crate::tex::find_tool;

pub(crate) const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_OUTPUT: usize = 1_000_000;
/// How long a finished child's pipes are read before giving up on them.
const DRAIN_GRACE: Duration = Duration::from_secs(2);

/// A tool and every process it starts, the engines latexmk or TeXpresso runs
/// among them, which stopping the tool alone would leak: a process group of
/// its own on Unix, a Job Object on Windows. Kept apart from the child, so a
/// Stop or quit kills the tree from any thread while another awaits the tool.
#[derive(Clone)]
pub(crate) struct Tree {
    #[cfg(unix)]
    group: i32,
    #[cfg(windows)]
    job: std::sync::Arc<job::Job>,
}

impl Tree {
    pub(crate) fn spawn(
        command: &mut tokio::process::Command,
    ) -> std::io::Result<(tokio::process::Child, Self)> {
        #[cfg(unix)]
        {
            let child = command.process_group(0).spawn()?;
            let group = child.id().expect("a child just spawned has its pid") as i32;
            Ok((child, Self { group }))
        }
        #[cfg(windows)]
        {
            // A console of its own that is never shown, which its engines
            // share: a console program a windowed app starts would open a
            // window for each pass.
            command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
            let mut child = command.spawn()?;
            let handle = child
                .raw_handle()
                .expect("a child just spawned has its handle");
            // Joined as it starts, long before it has loaded, let alone run a
            // program of its own.
            match job::Job::of(handle) {
                Ok(job) => Ok((
                    child,
                    Self {
                        job: std::sync::Arc::new(job),
                    },
                )),
                Err(err) => {
                    let _ = child.start_kill();
                    Err(err)
                }
            }
        }
    }

    pub(crate) fn kill(&self) {
        // SAFETY: a plain system call, on the group the tool leads.
        #[cfg(unix)]
        unsafe {
            libc::killpg(self.group, libc::SIGKILL);
        }
        #[cfg(windows)]
        self.job.kill();
    }
}

/// A Job Object that ends every process in it when it is killed, or when its
/// last handle closes: as the last owner of its tree here lets go, or the app
/// quits or crashes.
#[cfg(windows)]
mod job {
    use std::io;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle, RawHandle};

    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject,
    };

    pub(crate) struct Job(OwnedHandle);

    impl Job {
        /// A new job holding `process`, which takes every process it starts.
        pub(crate) fn of(process: RawHandle) -> io::Result<Self> {
            // SAFETY: no name and no attributes make an unnamed job with the
            // default security; the handle is owned from here.
            let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
            if handle.is_null() {
                return Err(io::Error::last_os_error());
            }
            let job = Self(unsafe { OwnedHandle::from_raw_handle(handle) });
            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            // SAFETY: the limits are of the class named, at their own size,
            // and both handles are open.
            let joined = unsafe {
                SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    (&raw const limits).cast(),
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                ) != 0
                    && AssignProcessToJobObject(handle, process) != 0
            };
            if joined {
                Ok(job)
            } else {
                Err(io::Error::last_os_error())
            }
        }

        pub(crate) fn kill(&self) {
            // SAFETY: the handle is open while self is.
            unsafe { TerminateJobObject(self.0.as_raw_handle(), 1) };
        }
    }
}

/// `program` as found in `path_env`, to run in `cwd` with that PATH and its
/// output piped.
pub(crate) fn command(
    program: &str,
    cwd: Option<&Path>,
    path_env: &str,
) -> std::io::Result<tokio::process::Command> {
    // A full path avoids std's fork fallback, which can crash a child of the
    // multithreaded Mac app before exec.
    let program = find_tool(program, path_env).ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("{program} is not on the PATH"),
        )
    })?;
    let mut cmd = tokio::process::Command::new(program);
    // TeX Live's engines read texmf.cnf's variables from the environment
    // first. Unwrapped, the log keeps each message and path on one line;
    // wrapped at the default 79 columns, words and paths split mid-way.
    cmd.env("PATH", path_env)
        .env("max_print_line", "10000")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    Ok(cmd)
}

/// Keep bounded output while draining to EOF, so a full pipe cannot block the
/// child. The caller keeps what was read if it ends the drain early.
async fn read_capped<R: tokio::io::AsyncRead + Unpin>(mut reader: R, kept: &mut Vec<u8>) {
    let mut capped = (&mut reader).take(MAX_OUTPUT as u64);
    if capped.read_to_end(kept).await.is_ok() {
        let _ = tokio::io::copy(&mut reader, &mut tokio::io::sink()).await;
    }
}

/// Spawn, collect capped output, and kill the whole tree on timeout: the exit
/// code (-1 for none, as after a timeout) and stdout. An error says why the
/// program could not start; `NotFound` when it is not on the PATH.
pub(crate) async fn run(
    program: &str,
    args: &[&str],
    cwd: Option<&Path>,
    timeout: Duration,
    path_env: &str,
) -> std::io::Result<(i32, String)> {
    let mut cmd = command(program, cwd, path_env)?;
    let (mut child, tree) = Tree::spawn(cmd.args(args))?;
    let (code, stdout, ..) = drive(&mut child, &tree, timeout).await;
    Ok((code, stdout))
}

/// Collect capped output while the child runs. On timeout, kill its process
/// tree before reaping; the final value reports whether it timed out.
pub(crate) async fn drive(
    child: &mut tokio::process::Child,
    tree: &Tree,
    timeout: Duration,
) -> (i32, String, String, bool) {
    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let (status, timed_out) = {
        let readers = async {
            tokio::join!(read_capped(stdout, &mut out), read_capped(stderr, &mut err),);
        };
        let wait = async {
            match tokio::time::timeout(timeout, child.wait()).await {
                Ok(status) => (status.ok(), false),
                Err(_) => {
                    tree.kill();
                    let _ = child.start_kill();
                    (child.wait().await.ok(), true)
                }
            }
        };
        tokio::pin!(readers, wait);
        tokio::select! {
            status = &mut wait => {
                // A descendant or unrelated inherited pipe can outlive the child.
                // Drain its buffered output briefly, then drop both read futures.
                let _ = tokio::time::timeout(DRAIN_GRACE, readers).await;
                status
            }
            () = &mut readers => wait.await,
        }
    };
    (
        status.and_then(|s| s.code()).unwrap_or(-1),
        crate::lossy_string(out),
        crate::lossy_string(err),
        timed_out,
    )
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn killing_a_tree_ends_the_tool() {
        let mut command = tokio::process::Command::new(if cfg!(windows) { "cmd" } else { "sh" });
        if cfg!(windows) {
            command.args(["/C", "ping -n 30 127.0.0.1 > NUL"]);
        } else {
            command.args(["-c", "sleep 30; true"]);
        }
        let (mut child, tree) = super::Tree::spawn(&mut command).unwrap();
        tree.kill();
        let ended = tokio::time::timeout(std::time::Duration::from_secs(5), child.wait());
        assert!(!ended.await.unwrap().unwrap().success());
    }

    #[tokio::test]
    async fn a_program_off_the_path_is_not_found_and_one_that_fails_has_its_code() {
        use std::time::Duration;
        let missing = super::run(
            "no-such-tool",
            &[],
            None,
            Duration::from_secs(5),
            "/nonexistent",
        );
        assert_eq!(
            missing.await.unwrap_err().kind(),
            std::io::ErrorKind::NotFound
        );
        if cfg!(unix) {
            let path = std::env::var("PATH").unwrap();
            let (code, stdout) = super::run(
                "sh",
                &["-c", "echo hi; exit 3"],
                None,
                Duration::from_secs(5),
                &path,
            )
            .await
            .unwrap();
            assert_eq!((code, stdout.trim()), (3, "hi"));
        }
    }
}
