use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::sync::Arc;

use texlocal_latex::FileKind;
use texlocal_latex::facts::Facts;
use texlocal_latex::file_kind;

use super::skip_unreadable;
use super::tree::visit_files;
use crate::error::CoreError;
use crate::paths::Project;
use crate::stamp::Kept;

pub fn scan_facts(
    project: &Project,
    facts: &Files,
    open: &HashMap<String, String>,
) -> Result<BTreeMap<String, Arc<Facts>>, CoreError> {
    let mut files = BTreeMap::new();
    visit_files(project, &mut |abs, rel| {
        let kind = file_kind(rel);
        if !matches!(kind, FileKind::Tex | FileKind::Bib) {
            return Ok(true);
        }
        let found = match open.get(rel) {
            Some(text) => Some(Arc::new(Facts::read(text, kind))),
            None => skip_unreadable(facts.0.get(abs, |abs| {
                let text = crate::lf(crate::lossy_string(fs::read(abs)?));
                Ok::<_, std::io::Error>(Facts::read(&text, kind))
            }))?,
        };
        files.extend(found.map(|found| (rel.to_owned(), found)));
        Ok(true)
    })?;
    Ok(files)
}

pub struct Files(Kept<Facts>);

impl Default for Files {
    fn default() -> Self {
        Self(Kept::holding(4096))
    }
}
