use std::io;
use std::path::Path;
use std::process::{ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::{Child, Command};

use crate::tex::find_tool;
use crate::{lock, sys};

const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_OUTPUT: u64 = 1_000_000;
const DRAIN_GRACE: Duration = Duration::from_secs(2);

#[derive(Clone)]
pub(crate) struct Tree(Arc<Mutex<Option<u32>>>);

impl Tree {
    pub(crate) fn spawn(command: &mut Command) -> io::Result<(Child, Self)> {
        let (child, group) = sys::spawn_group(command)?;
        Ok((child, Self(Arc::new(Mutex::new(Some(group))))))
    }

    pub(crate) fn kill(&self) {
        if let Some(group) = *lock(&self.0) {
            sys::kill_group(group);
        }
    }

    pub(crate) async fn ended(&self, child: &mut Child) -> io::Result<ExitStatus> {
        let pid = child.id().expect("not reaped yet");
        let _ = tokio::task::spawn_blocking(move || sys::wait_exited(pid)).await;
        if let Some(group) = lock(&self.0).take() {
            sys::kill_group(group);
        }
        child.wait().await
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
    cmd.env("max_print_line", "10000");
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    Ok(cmd)
}

pub(crate) fn tool(program: &Path, path_env: &str) -> Command {
    let mut cmd = Command::new(program);
    cmd.env("PATH", path_env)
        .stdin(Stdio::null())
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

pub(crate) async fn run(program: &str, args: &[&str], path_env: &str) -> io::Result<(i32, String)> {
    let mut cmd = command(program, None, path_env)?;
    let (mut child, tree) = Tree::spawn(cmd.args(args))?;
    let (code, output, _) = drive(&mut child, &tree, Some(PROBE_TIMEOUT)).await;
    Ok((code, output))
}

pub(crate) async fn drive(
    child: &mut Child,
    tree: &Tree,
    timeout: Option<Duration>,
) -> (i32, String, bool) {
    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let (status, timed_out) = {
        let readers = async {
            tokio::join!(read_capped(stdout, &mut out), read_capped(stderr, &mut err));
        };
        let wait = async {
            let limit = timeout.unwrap_or(Duration::MAX);
            match tokio::time::timeout(limit, tree.ended(child)).await {
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
    out.append(&mut err);
    let code = status.and_then(|s| s.code()).unwrap_or(-1);
    (code, crate::lossy_string(out), timed_out)
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn sh(script: &str, timeout: Option<Duration>) -> (i32, String, bool) {
        let mut command = command("sh", None, "/bin").unwrap();
        let (mut child, tree) = Tree::spawn(command.args(["-c", script])).unwrap();
        drive(&mut child, &tree, timeout).await
    }

    #[tokio::test]
    async fn a_run_gives_its_code_and_output_then_errors_and_is_stopped_at_its_timeout() {
        let script = "echo out; echo err >&2; exit 3";
        assert_eq!(sh(script, None).await, (3, "out\nerr\n".into(), false));
        let script = "echo out; echo err >&2; sleep 30";
        let timeout = Some(Duration::from_secs(1));
        assert_eq!(sh(script, timeout).await, (-1, "out\nerr\n".into(), true));
    }
}
