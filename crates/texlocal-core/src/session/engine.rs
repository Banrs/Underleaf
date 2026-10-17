//! The programs a session runs, latexmk and TeXpresso, behind one seam, so
//! the session's rules are tested without them. A preview is its session's,
//! by the session's number (`owner`).

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use crate::CoreError;
use crate::compile::CompileResult;
use crate::service::Service;
use crate::texpresso::{Events, FileBuffer, Pane, Status};

pub(crate) type Fut<T> = Pin<Box<dyn Future<Output = T> + Send>>;

pub(crate) trait Engine: Send + Sync {
    fn compile(&self, root: PathBuf) -> Fut<Result<CompileResult, CoreError>>;
    fn stop_compile(&self, root: &Path);
    fn clean(&self, root: PathBuf) -> Fut<Result<(), CoreError>>;
    fn live_start(
        &self,
        owner: u64,
        root: &Path,
        files: &[FileBuffer],
        replacing: bool,
        pane: Option<&Pane>,
    ) -> Result<Status, CoreError>;
    fn live_update(&self, owner: u64, path: &str, text: &str) -> Result<(), CoreError>;
    fn live_edit(
        &self,
        owner: u64,
        path: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<(), CoreError>;
    fn live_view(&self, owner: u64, first: u32, last: u32);
    fn live_caret(&self, owner: u64, path: &str, offset: usize);
    fn live_wait(&self, owner: u64, after: u64) -> Fut<Result<Events, CoreError>>;
    fn live_stop(&self, owner: u64) -> Result<Status, CoreError>;
    fn live_rescan(&self, owner: u64) -> Result<Status, CoreError>;
    fn live_status(&self, owner: u64) -> Result<Status, CoreError>;
}

/// The engine of a real host: the service's compile and TeXpresso managers.
pub(crate) struct ServiceEngine(pub Arc<Service>);

impl Engine for ServiceEngine {
    fn compile(&self, root: PathBuf) -> Fut<Result<CompileResult, CoreError>> {
        let service = Arc::clone(&self.0);
        Box::pin(async move {
            service
                .compile
                .compile(&root, &service.tool_paths().0)
                .await
        })
    }

    fn stop_compile(&self, root: &Path) {
        self.0.compile.stop(root);
    }

    fn clean(&self, root: PathBuf) -> Fut<Result<(), CoreError>> {
        let service = Arc::clone(&self.0);
        Box::pin(async move { service.compile.clean(&root).await })
    }

    fn live_start(
        &self,
        owner: u64,
        root: &Path,
        files: &[FileBuffer],
        replacing: bool,
        pane: Option<&Pane>,
    ) -> Result<Status, CoreError> {
        let path_env = self.0.tool_paths().1;
        let manager = &self.0.texpresso;
        manager.start(owner, root, files, replacing, &path_env, pane)
    }

    fn live_update(&self, owner: u64, path: &str, text: &str) -> Result<(), CoreError> {
        self.0.texpresso.update(owner, path, text)
    }

    fn live_edit(
        &self,
        owner: u64,
        path: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<(), CoreError> {
        self.0.texpresso.edit(owner, path, start, remove, text)
    }

    fn live_view(&self, owner: u64, first: u32, last: u32) {
        let _ = self.0.texpresso.view(owner, first, last);
    }

    fn live_caret(&self, owner: u64, path: &str, offset: usize) {
        let _ = self.0.texpresso.caret(owner, path, offset);
    }

    fn live_wait(&self, owner: u64, after: u64) -> Fut<Result<Events, CoreError>> {
        let service = Arc::clone(&self.0);
        Box::pin(async move { service.texpresso.wait(owner, after).await })
    }

    fn live_stop(&self, owner: u64) -> Result<Status, CoreError> {
        self.0.texpresso.stop_request(owner)
    }

    fn live_rescan(&self, owner: u64) -> Result<Status, CoreError> {
        self.0.texpresso.rescan(owner)
    }

    fn live_status(&self, owner: u64) -> Result<Status, CoreError> {
        self.0.texpresso.status(owner)
    }
}
