use std::collections::HashSet;
use std::io;
use std::path::Path;
use std::process::{ExitStatus, Stdio};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::{Child, Command};

use crate::tex::find_tool;
use crate::{lock, sys};

const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_OUTPUT: u64 = 1_000_000;
const DRAIN_GRACE: Duration = Duration::from_secs(2);

type Group = Mutex<Option<u32>>;

#[derive(Clone)]
pub(crate) struct Tree(Arc<Group>);

#[derive(Default)]
pub(crate) struct Processes(Mutex<Registry>);

#[derive(Default)]
struct Registry {
    quit: bool,
    last: u64,
    owners: HashSet<u64>,
    trees: Vec<(Option<u64>, Weak<Group>)>,
}

impl Processes {
    pub(crate) fn owner(&self) -> u64 {
        let mut registry = lock(&self.0);
        registry.last += 1;
        let owner = registry.last;
        registry.owners.insert(owner);
        owner
    }

    pub(crate) fn spawn(
        &self,
        owner: Option<u64>,
        command: &mut Command,
    ) -> io::Result<(Child, Tree)> {
        let mut registry = lock(&self.0);
        if registry.quit || owner.is_some_and(|owner| !registry.owners.contains(&owner)) {
            return Err(io::ErrorKind::Interrupted.into());
        }
        let (child, tree) = Tree::spawn(command)?;
        registry.trees.retain(|(_, tree)| tree.strong_count() > 0);
        registry.trees.push((owner, Arc::downgrade(&tree.0)));
        Ok((child, tree))
    }

    pub(crate) fn kill_all(&self) {
        let mut registry = lock(&self.0);
        registry.quit = true;
        registry.kill(|_| true);
    }

    pub(crate) fn end(&self, owner: u64) {
        let mut registry = lock(&self.0);
        registry.owners.remove(&owner);
        registry.kill(|of| of == Some(owner));
    }

    pub(crate) fn quit(&self) -> bool {
        lock(&self.0).quit
    }
}

impl Registry {
    fn kill(&self, chosen: impl Fn(Option<u64>) -> bool) {
        for (owner, tree) in &self.trees {
            if let Some(tree) = tree.upgrade().filter(|_| chosen(*owner)) {
                Tree(tree).kill();
            }
        }
    }
}

impl Tree {
    fn spawn(command: &mut Command) -> io::Result<(Child, Self)> {
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
    sys::default_signals(&mut cmd);
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
    processes: &Processes,
    program: &str,
    args: &[&str],
    path_env: &str,
) -> io::Result<(i32, String)> {
    let mut cmd = command(program, None, path_env)?;
    let (mut child, tree) = processes.spawn(None, cmd.args(args))?;
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
    use std::os::unix::process::ExitStatusExt;

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

    #[tokio::test]
    async fn a_sessions_children_end_with_it_and_every_child_at_quit() {
        let processes = Processes::default();
        let sleep = || {
            let mut command = command("sleep", None, "/bin").unwrap();
            command.arg("30");
            command
        };
        let (session, other) = (processes.owner(), processes.owner());
        let (mut ended, _ended) = processes.spawn(Some(session), &mut sleep()).unwrap();
        let (mut other, _other) = processes.spawn(Some(other), &mut sleep()).unwrap();
        let (mut probe, _probe) = processes.spawn(None, &mut sleep()).unwrap();
        processes.end(session);
        assert_eq!(ended.wait().await.unwrap().signal(), Some(9));
        assert!(processes.spawn(Some(session), &mut sleep()).is_err());
        let still = tokio::time::timeout(Duration::from_millis(200), other.wait()).await;
        assert!(still.is_err(), "another session's child ended too");
        processes.kill_all();
        for child in [&mut other, &mut probe] {
            assert_eq!(child.wait().await.unwrap().signal(), Some(9));
        }
        assert!(processes.spawn(None, &mut sleep()).is_err());
    }
}
