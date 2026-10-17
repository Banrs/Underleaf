//! The programs a session runs, latexmk and TeXpresso, behind one seam, so
//! the session's rules are tested without them; a real host's engine is the
//! service. A preview is its session's, by the session's number (`owner`).

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use crate::CoreError;
use crate::compile::CompileResult;
use crate::service::Service;
use crate::texpresso::{Events, FileBuffer, Pane, Status};

pub(crate) type Fut<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// What a session asks of its preview, as `texpresso::Manager` takes it.
#[derive(Debug)]
pub(crate) enum Call<'a> {
    Start {
        root: &'a Path,
        files: &'a [FileBuffer],
        replacing: bool,
        pane: Option<&'a Pane>,
    },
    /// A file's whole text.
    Update(&'a str, &'a str),
    /// A key's edit: UTF-16 units removed at a place, and the text put there.
    Edit(&'a str, usize, usize, &'a str),
    View(u32, u32),
    Caret(&'a str, usize),
    Stop,
    Rescan,
    Status,
}

pub(crate) trait Engine: Send + Sync {
    fn compile(self: Arc<Self>, root: PathBuf) -> Fut<Result<CompileResult, CoreError>>;
    fn stop_compile(&self, root: &Path);
    fn clean(self: Arc<Self>, root: PathBuf) -> Fut<Result<(), CoreError>>;
    /// The preview's status, for the calls that answer one; else a default.
    fn live(&self, owner: u64, call: Call) -> Result<Status, CoreError>;
    fn live_wait(self: Arc<Self>, owner: u64, after: u64) -> Fut<Result<Events, CoreError>>;
}

impl Engine for Service {
    fn compile(self: Arc<Self>, root: PathBuf) -> Fut<Result<CompileResult, CoreError>> {
        Box::pin(async move { self.compile.compile(&root, self.tex_dir().as_deref()).await })
    }

    fn stop_compile(&self, root: &Path) {
        self.compile.stop(root);
    }

    fn clean(self: Arc<Self>, root: PathBuf) -> Fut<Result<(), CoreError>> {
        Box::pin(async move { self.compile.clean(&root).await })
    }

    fn live(&self, owner: u64, call: Call) -> Result<Status, CoreError> {
        let manager = &self.texpresso;
        let done = |result: Result<(), CoreError>| result.map(|()| Status::default());
        match call {
            Call::Start { root, files, replacing, pane } => {
                manager.start(owner, root, files, replacing, &self.tool_paths().1, pane)
            }
            Call::Update(path, text) => done(manager.update(owner, path, text)),
            Call::Edit(path, start, remove, text) => {
                done(manager.edit(owner, path, start, remove, text))
            }
            Call::View(first, last) => done(manager.view(owner, first, last)),
            Call::Caret(path, offset) => done(manager.caret(owner, path, offset)),
            Call::Stop => manager.stop_request(owner),
            Call::Rescan => manager.rescan(owner),
            Call::Status => manager.status(owner),
        }
    }

    fn live_wait(self: Arc<Self>, owner: u64, after: u64) -> Fut<Result<Events, CoreError>> {
        Box::pin(async move { self.texpresso.wait(owner, after).await })
    }
}
