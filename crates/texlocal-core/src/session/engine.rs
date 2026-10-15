//! The programs a session runs, latexmk and TeXpresso, behind one seam, so
//! the session's rules are tested without them.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use crate::CoreError;
use crate::compile::CompileResult;
use crate::service::Service;
use crate::texpresso::{Events, FileBuffer, Pane, Status};

pub(crate) type Fut<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// The longest a live preview's wait for news lasts before it asks again.
const WAIT: Duration = Duration::from_secs(30);

pub(crate) trait Engine: Send + Sync {
    fn compile(&self, root: PathBuf) -> Fut<Result<CompileResult, CoreError>>;
    fn stop_compile(&self, root: &Path);
    fn clean(&self, root: PathBuf) -> Fut<Result<(), CoreError>>;
    fn live_start(
        &self,
        root: PathBuf,
        files: Vec<FileBuffer>,
        expected: Option<String>,
        pane: Pane,
    ) -> Fut<Result<Status, CoreError>>;
    fn live_update(
        &self,
        root: PathBuf,
        path: String,
        text: String,
        token: String,
    ) -> Fut<Result<u64, CoreError>>;
    fn live_edit(
        &self,
        token: &str,
        path: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<u64, CoreError>;
    fn live_view(&self, token: &str, first: u32, last: u32);
    fn live_caret(&self, token: &str, path: &str, offset: usize);
    fn live_wait(&self, root: PathBuf, token: String, after: u64)
    -> Fut<Result<Events, CoreError>>;
    fn live_stop(&self, root: PathBuf, token: String) -> Fut<Result<Status, CoreError>>;
    fn live_rescan(&self, root: PathBuf, token: String) -> Fut<Result<Status, CoreError>>;
    fn live_status(&self, root: &Path, token: Option<&str>) -> Result<Status, CoreError>;
}

/// The engine of a real host: the service's compile and TeXpresso managers.
pub(crate) struct ServiceEngine(pub Arc<Service>);

impl Engine for ServiceEngine {
    fn compile(&self, root: PathBuf) -> Fut<Result<CompileResult, CoreError>> {
        let service = Arc::clone(&self.0);
        Box::pin(async move {
            let tex_dir = service.tex_dir();
            service.compile.compile(&root, tex_dir.as_deref()).await
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
        root: PathBuf,
        files: Vec<FileBuffer>,
        expected: Option<String>,
        pane: Pane,
    ) -> Fut<Result<Status, CoreError>> {
        let service = Arc::clone(&self.0);
        Box::pin(async move {
            let path_env = service.tool_paths().1;
            let manager = &service.texpresso;
            manager
                .start(&root, &files, expected.as_deref(), &path_env, &pane)
                .await
        })
    }

    fn live_update(
        &self,
        root: PathBuf,
        path: String,
        text: String,
        token: String,
    ) -> Fut<Result<u64, CoreError>> {
        let service = Arc::clone(&self.0);
        Box::pin(async move {
            let updated = service.texpresso.update(&root, &path, &text, &token, true);
            Ok(updated.await?.edit)
        })
    }

    fn live_edit(
        &self,
        token: &str,
        path: &str,
        start: usize,
        remove: usize,
        text: &str,
    ) -> Result<u64, CoreError> {
        self.0.texpresso.edit(token, path, start, remove, text)
    }

    fn live_view(&self, token: &str, first: u32, last: u32) {
        let _ = self.0.texpresso.view(token, first, last);
    }

    fn live_caret(&self, token: &str, path: &str, offset: usize) {
        let _ = self.0.texpresso.caret(token, path, offset);
    }

    fn live_wait(
        &self,
        root: PathBuf,
        token: String,
        after: u64,
    ) -> Fut<Result<Events, CoreError>> {
        let service = Arc::clone(&self.0);
        Box::pin(async move { service.texpresso.wait(&root, &token, after, WAIT).await })
    }

    fn live_stop(&self, root: PathBuf, token: String) -> Fut<Result<Status, CoreError>> {
        let service = Arc::clone(&self.0);
        Box::pin(async move {
            let path_env = service.tool_paths().1;
            let stop = service
                .texpresso
                .stop_request(&root, Some(&token), &path_env);
            stop.await
        })
    }

    fn live_rescan(&self, root: PathBuf, token: String) -> Fut<Result<Status, CoreError>> {
        let service = Arc::clone(&self.0);
        Box::pin(async move { service.texpresso.rescan(&root, &token).await })
    }

    fn live_status(&self, root: &Path, token: Option<&str>) -> Result<Status, CoreError> {
        self.0
            .texpresso
            .status(root, token, || self.0.tool_paths().1)
    }
}
