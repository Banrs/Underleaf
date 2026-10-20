//! latexmk behind a seam, so the session's rules are tested without it. TeXpresso's is
//! `texpresso::Preview`.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use crate::CoreError;
use crate::compile::{CompileManager, CompileResult};
use crate::service::Service;

pub(crate) type Fut<T> = Pin<Box<dyn Future<Output = T> + Send>>;

pub(crate) trait Engine: Send + Sync {
    fn compile(&self, root: PathBuf) -> Fut<Result<CompileResult, CoreError>>;
    fn stop_compile(&self, root: &Path);
    fn clean(&self, root: PathBuf) -> Fut<Result<(), CoreError>>;
}

impl Engine for Arc<Service> {
    fn compile(&self, root: PathBuf) -> Fut<Result<CompileResult, CoreError>> {
        let service = Self::clone(self);
        Box::pin(async move {
            service
                .compile
                .compile(&root, &service.tool_paths().0)
                .await
        })
    }

    fn stop_compile(&self, root: &Path) {
        self.compile.stop(root);
    }

    fn clean(&self, root: PathBuf) -> Fut<Result<(), CoreError>> {
        Box::pin(async move { CompileManager::clean(&root) })
    }
}
