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

#[derive(Clone)]
pub(crate) struct Tree {
    group: std::sync::Arc<std::sync::Mutex<Option<i32>>>,
}

impl Tree {
    pub(crate) fn spawn(command: &mut Command) -> io::Result<(Child, Self)> {
        let child = command.process_group(0).spawn()?;
        let group = child.id().expect("a child just spawned has its pid") as i32;
        let group = std::sync::Arc::new(std::sync::Mutex::new(Some(group)));
        Ok((child, Self { group }))
    }

    pub(crate) fn kill(&self) {
        if let Some(group) = *crate::lock(&self.group) {
            unsafe {
                libc::killpg(group, libc::SIGKILL);
            }
        }
    }

    pub(crate) async fn ended(&self, child: &mut Child) -> io::Result<ExitStatus> {
        let pid = child.id().expect("not reaped yet") as libc::id_t;
        let _ = tokio::task::spawn_blocking(move || exited(pid)).await;
        if let Some(group) = crate::lock(&self.group).take() {
            unsafe {
                libc::killpg(group, libc::SIGKILL);
            }
        }
        child.wait().await
    }
}

fn exited(pid: libc::id_t) {
    unsafe {
        let mut info: libc::siginfo_t = std::mem::zeroed();
        let flags = libc::WEXITED | libc::WNOWAIT;
        while libc::waitid(libc::P_PID, pid, &raw mut info, flags) == -1
            && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted
        {}
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
    cmd.env("max_print_line", "10000").stdin(Stdio::null());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    Ok(cmd)
}

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

pub(crate) async fn drive(
    child: &mut Child,
    tree: &Tree,
    timeout: Option<Duration>,
) -> (i32, String, String, bool) {
    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let (status, timed_out) = {
        let readers = async {
            tokio::join!(read_capped(stdout, &mut out), read_capped(stderr, &mut err));
        };
        let wait = async {
            let Some(timeout) = timeout else {
                return (tree.ended(child).await.ok(), false);
            };
            match tokio::time::timeout(timeout, tree.ended(child)).await {
                Ok(status) => (status.ok(), false),
                Err(_) => {
                    tree.kill();
                    (tree.ended(child).await.ok(), true)
                }
            }
        };
        tokio::pin!(readers, wait);
        tokio::select! {
            status = &mut wait => {
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
