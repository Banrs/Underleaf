use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::{fs, io};

use texlocal_latex::facts::Facts;
use texlocal_latex::{FileKind, file_kind, fold_case};

use super::skip_unreadable;
use super::tree::visit_files;
use crate::error::CoreError;
use crate::lock;
use crate::stamp::Stamp;

pub fn scan_facts(
    root: &Path,
    facts: &Files,
    open: &HashMap<String, String>,
) -> Result<BTreeMap<String, Arc<Facts>>, CoreError> {
    let mut files = BTreeMap::new();
    visit_files(root, &mut |abs, rel| {
        let kind = file_kind(rel);
        if !matches!(kind, FileKind::Tex | FileKind::Bib) {
            return Ok(true);
        }
        let found = match open.get(rel) {
            Some(text) => Some(Arc::new(Facts::read(text, kind))),
            None => skip_unreadable(facts.facts(abs, rel))?,
        };
        files.extend(found.map(|found| (rel.to_owned(), found)));
        Ok(true)
    })?;
    facts.keep(files.keys());
    Ok(files)
}

#[derive(Default)]
pub struct Files(Mutex<HashMap<String, (Stamp, Arc<Facts>)>>);

impl Files {
    pub fn facts(&self, abs: &Path, rel: &str) -> io::Result<Arc<Facts>> {
        let stamp = Stamp::at(abs)?;
        let key = fold_case(rel);
        if let Some((read, facts)) = lock(&self.0).get(&key)
            && *read == stamp
            && stamp.modified % 1_000_000_000 != 0
        {
            return Ok(Arc::clone(facts));
        }
        let text = crate::lf(crate::lossy_string(fs::read(abs)?));
        let facts = Arc::new(Facts::read(&text, file_kind(rel)));
        lock(&self.0).insert(key, (stamp, Arc::clone(&facts)));
        Ok(facts)
    }

    pub fn keep<'a>(&self, rels: impl Iterator<Item = &'a String>) {
        let kept: HashSet<String> = rels.map(|rel| fold_case(rel)).collect();
        lock(&self.0).retain(|key, _| kept.contains(key));
    }
}
