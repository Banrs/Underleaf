//! Running TeX's tools: a command with the augmented PATH, its whole process tree
//! killed together, and output kept to a cap while the child runs.

use std::io;
use std::path::Path;
use std::process::{ExitStatus, Stdio};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::{Child, Command};

use crate::tex::find_tool;

pub(crate) const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_OUTPUT: u64 = 1_000_000;
const DRAIN_GRACE: Duration = Duration::from_secs(2);

/// A tool and every process it starts, which stopping the tool alone would leak: a process
/// group on Unix, a Job Object on Windows. Kept apart from the child so a Stop or quit can
/// kill the tree from any thread while another awaits the tool.
#[derive(Clone)]
pub(crate) struct Tree {
    /// None once the tool is to be reaped, after which its pid may be another's.
    #[cfg(unix)]
    group: std::sync::Arc<std::sync::Mutex<Option<i32>>>,
    #[cfg(windows)]
    job: std::sync::Arc<std::os::windows::io::OwnedHandle>,
}

impl Tree {
    pub(crate) fn spawn(command: &mut Command) -> io::Result<(Child, Self)> {
        #[cfg(unix)]
        {
            let child = command.process_group(0).spawn()?;
            let group = child.id().expect("a child just spawned has its pid") as i32;
            let group = std::sync::Arc::new(std::sync::Mutex::new(Some(group)));
            Ok((child, Self { group }))
        }
        #[cfg(windows)]
        {
            use windows_sys::Win32::System::Threading::{CREATE_NO_WINDOW, CREATE_SUSPENDED};
            // A console of its own that is never shown: a console program a windowed app starts
            // would open a window for each pass. Suspended until it is in the job, as what it
            // started before would be outside it.
            command.creation_flags(CREATE_NO_WINDOW | CREATE_SUSPENDED);
            let mut child = command.spawn()?;
            let process = child
                .raw_handle()
                .expect("a child just spawned has its handle");
            let pid = child.id().expect("a child just spawned has its pid");
            let job = job_of(process).and_then(|job| resume(pid).map(|()| job));
            let job = job.inspect_err(|_| {
                let _ = child.start_kill();
            })?;
            Ok((child, Self { job: job.into() }))
        }
    }

    pub(crate) fn kill(&self) {
        // SAFETY: plain system calls, on the group the tool leads, held so it isn't reaped
        // meanwhile, or the job's open handle.
        #[cfg(unix)]
        if let Some(group) = *crate::lock(&self.group) {
            unsafe {
                libc::killpg(group, libc::SIGKILL);
            }
        }
        #[cfg(windows)]
        unsafe {
            use std::os::windows::io::AsRawHandle;
            windows_sys::Win32::System::JobObjects::TerminateJobObject(self.job.as_raw_handle(), 1);
        }
    }

    /// The tool's exit, once what it started is killed too. On Unix the tree goes before the
    /// tool is reaped: until then the tool's pid, which names the group, is no other process's.
    pub(crate) async fn ended(&self, child: &mut Child) -> io::Result<ExitStatus> {
        #[cfg(unix)]
        {
            let pid = child.id().expect("not reaped yet") as libc::id_t;
            let _ = tokio::task::spawn_blocking(move || exited(pid)).await;
            if let Some(group) = crate::lock(&self.group).take() {
                // SAFETY: a plain system call on the group, its leader a zombie still.
                unsafe {
                    libc::killpg(group, libc::SIGKILL);
                }
            }
            child.wait().await
        }
        #[cfg(windows)]
        {
            let status = child.wait().await;
            self.kill();
            status
        }
    }
}

/// Once the process `pid` has ended, which it leaves to be reaped.
#[cfg(unix)]
fn exited(pid: libc::id_t) {
    // SAFETY: an info of the size waitid writes, for a child of this process.
    unsafe {
        let mut info: libc::siginfo_t = std::mem::zeroed();
        let flags = libc::WEXITED | libc::WNOWAIT;
        while libc::waitid(libc::P_PID, pid, &raw mut info, flags) == -1
            && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted
        {}
    }
}

/// A Job Object holding `process` that ends every process in it when it is killed or its
/// last handle closes.
#[cfg(windows)]
fn job_of(
    process: std::os::windows::io::RawHandle,
) -> io::Result<std::os::windows::io::OwnedHandle> {
    use std::os::windows::io::{FromRawHandle, OwnedHandle};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject,
    };
    // SAFETY: no name and no attributes make an unnamed job with the default security; the
    // handle is owned from here.
    let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
    if handle.is_null() {
        return Err(io::Error::last_os_error());
    }
    let job = unsafe { OwnedHandle::from_raw_handle(handle) };
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // SAFETY: the limits are of the class named, at their own size, and both handles are open.
    let joined = unsafe {
        SetInformationJobObject(
            handle,
            JobObjectExtendedLimitInformation,
            (&raw const limits).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        ) != 0
            && AssignProcessToJobObject(handle, process) != 0
    };
    joined.then_some(job).ok_or_else(io::Error::last_os_error)
}

/// The threads of the process `pid` made suspended: its first, which std keeps no handle to.
#[cfg(windows)]
fn resume(pid: u32) -> io::Result<()> {
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
    };
    use windows_sys::Win32::System::Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME};
    // SAFETY: a snapshot of the system's threads, walked with an entry of its own size; each
    // handle opened is owned, so closed.
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        let snapshot = OwnedHandle::from_raw_handle(snapshot);
        let mut entry = THREADENTRY32 {
            dwSize: size_of::<THREADENTRY32>() as u32,
            ..THREADENTRY32::default()
        };
        let (mut more, mut resumed) = (
            Thread32First(snapshot.as_raw_handle(), &raw mut entry),
            false,
        );
        while more != 0 {
            if entry.th32OwnerProcessID == pid {
                let thread = OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID);
                if !thread.is_null() {
                    let thread = OwnedHandle::from_raw_handle(thread);
                    resumed |= ResumeThread(thread.as_raw_handle()) != u32::MAX;
                }
            }
            more = Thread32Next(snapshot.as_raw_handle(), &raw mut entry);
        }
        resumed.then_some(()).ok_or_else(io::Error::last_os_error)
    }
}

pub(crate) fn command(program: &str, cwd: Option<&Path>, path_env: &str) -> io::Result<Command> {
    let program = find_tool(program, path_env).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("{program} is not on the PATH"),
        )
    })?;
    let mut cmd = tool(&program, path_env);
    // TeX Live's engines read texmf.cnf's variables from the environment first; unwrapped,
    // the log keeps each message and path on one line.
    cmd.env("max_print_line", "10000").stdin(Stdio::null());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    Ok(cmd)
}

/// The program at the full path `program`, run with `path_env` as its PATH, output piped,
/// and killed if dropped. A full path avoids std's fork fallback, which can crash a child
/// of the multithreaded Mac app before exec.
pub(crate) fn tool(program: &Path, path_env: &str) -> Command {
    let mut cmd = Command::new(program);
    cmd.env("PATH", path_env)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    cmd
}

async fn read_capped(mut reader: impl AsyncRead + Unpin, kept: &mut Vec<u8>) {
    if (&mut reader)
        .take(MAX_OUTPUT)
        .read_to_end(kept)
        .await
        .is_ok()
    {
        let _ = tokio::io::copy(&mut reader, &mut tokio::io::sink()).await;
    }
}

pub(crate) async fn run(
    program: &str,
    args: &[&str],
    cwd: Option<&Path>,
    path_env: &str,
) -> io::Result<(i32, String)> {
    let mut cmd = command(program, cwd, path_env)?;
    let (mut child, tree) = Tree::spawn(cmd.args(args))?;
    let (code, stdout, ..) = drive(&mut child, &tree, Some(PROBE_TIMEOUT)).await;
    Ok((code, stdout))
}

/// The exit code (-1 for none), stdout, stderr, and whether the timeout killed the tree.
pub(crate) async fn drive(
    child: &mut Child,
    tree: &Tree,
    timeout: Option<Duration>,
) -> (i32, String, String, bool) {
    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");
    let (mut out, mut err) = (Vec::new(), Vec::new());
    // In a block of its own: the futures borrow `out` and `err` until they are dropped.
    let (status, timed_out) = {
        let readers = async {
            tokio::join!(read_capped(stdout, &mut out), read_capped(stderr, &mut err));
        };
        let wait = async {
            let Some(timeout) = timeout else {
                return (child.wait().await.ok(), false);
            };
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
                // A descendant or unrelated inherited pipe can outlive the child: drain briefly, then drop.
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
    use super::*;

    #[tokio::test]
    async fn killing_a_tree_ends_the_tool() {
        let (shell, script) = if cfg!(windows) {
            ("cmd", ["/C", "ping -n 30 127.0.0.1 > NUL"])
        } else {
            ("sh", ["-c", "sleep 30; true"])
        };
        let (mut child, tree) = Tree::spawn(Command::new(shell).args(script)).unwrap();
        tree.kill();
        let ended = tokio::time::timeout(PROBE_TIMEOUT, child.wait());
        assert!(!ended.await.unwrap().unwrap().success());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn what_a_tool_leaves_running_ends_with_it() {
        let mut command = Command::new("sh");
        command
            .args(["-c", "sleep 30 & exit 0"])
            .stdout(Stdio::piped());
        let (mut child, tree) = Tree::spawn(&mut command).unwrap();
        let mut out = child.stdout.take().unwrap();
        assert!(tree.ended(&mut child).await.unwrap().success());
        // The sleep holds the pipe until it is killed.
        let mut rest = Vec::new();
        let closed = tokio::time::timeout(PROBE_TIMEOUT, out.read_to_end(&mut rest));
        assert!(closed.await.is_ok());
    }

    #[tokio::test]
    async fn a_program_off_the_path_is_not_found_and_one_that_fails_has_its_code() {
        let missing = run("no-such-tool", &[], None, "/nonexistent").await;
        assert_eq!(missing.unwrap_err().kind(), io::ErrorKind::NotFound);
        if cfg!(unix) {
            let path = std::env::var("PATH").unwrap();
            let sh = run("sh", &["-c", "echo 3; exit 3"], None, &path);
            assert_eq!(sh.await.unwrap(), (3, "3\n".to_string()));
        }
    }
}
