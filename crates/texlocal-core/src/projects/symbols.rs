use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::{fs, io};

use texlocal_latex::facts::Facts;
pub use texlocal_latex::syntax::Symbols;
use texlocal_latex::{FileKind, file_kind, fold_case};

use super::skip_unreadable;
use super::tree::visit_files;
use crate::error::CoreError;
use crate::lock;
use crate::stamp::Stamp;

pub fn scan_symbols(
    root: &Path,
    facts: &Files,
    open: &HashMap<String, String>,
) -> Result<Symbols, CoreError> {
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
    fn firsts<'a, T: Clone>(
        all: impl Iterator<Item = &'a T>,
        name: fn(&'a T) -> &'a str,
    ) -> Vec<T> {
        let mut seen = HashSet::new();
        all.filter(|item| seen.insert(name(item)))
            .cloned()
            .collect()
    }
    let all = || files.values().map(|facts| &**facts);
    let environments = all().flat_map(|f| &f.environments).map(|e| &e.name);
    Ok(Symbols {
        citations: firsts(all().flat_map(|f| &f.citations), |c| &c.name),
        labels: firsts(all().flat_map(|f| &f.labels), |l| &l.name),
        commands: firsts(all().flat_map(|f| &f.commands), |c| &c.name),
        environments: firsts(environments, String::as_str),
        by_file: files,
        ..Symbols::default()
    })
}

#[derive(Default)]
pub struct Files(Mutex<HashMap<String, (Stamp, Arc<Facts>)>>);

impl Files {
    pub fn facts(&self, abs: &Path, rel: &str) -> io::Result<Arc<Facts>> {
        let stamp = Stamp::of(&fs::metadata(abs)?);
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
