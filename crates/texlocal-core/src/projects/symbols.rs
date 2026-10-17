//! The labels and citation keys a project defines, for completion.

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

use super::skip_unreadable;
use super::tree::{file_kind, visit_files};
use crate::error::CoreError;
use crate::stamp::Stamp;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Symbols {
    pub citations: Vec<String>,
    pub labels: Vec<String>,
}

// Matched on the decoded text, not the raw bytes: in Unicode mode a byte that
// isn't UTF-8 (a Latin-1 umlaut) drops its entry, and `(?-u)` narrows `\s` to
// ASCII, which swallows a non-breaking space into the key.
static BIB_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"@[0-9A-Za-z_]+\s*\{\s*([^,\s]+)\s*,").unwrap());
/// Not a bare prefix, as an inserted block's `fig:` is until it's filled in.
static LABEL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\\label\{([^}]*[^}:])\}").unwrap());
/// A thebibliography entry's key, which \cite takes as a .bib key.
static BIBITEM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\\bibitem\s*(?:\[[^\]]*\])?\s*\{([^}]+)\}").unwrap());

/// A line of TeX without its comment, which starts at the first % that no
/// backslash escapes.
fn uncommented(line: &str) -> &str {
    let mut escaped = false;
    for (i, c) in line.char_indices() {
        match c {
            '%' if !escaped => return &line[..i],
            '\\' => escaped = !escaped,
            _ => escaped = false,
        }
    }
    line
}

fn parse_symbols(bytes: &[u8], kind: &str) -> Symbols {
    let mut citations = Vec::new();
    let mut labels = Vec::new();
    let text = String::from_utf8_lossy(bytes);
    let found = |re: &Regex, text: &str, out: &mut Vec<String>| {
        out.extend(re.captures_iter(text).map(|m| m[1].to_string()));
    };
    if kind == "bib" {
        found(&BIB_KEY, &text, &mut citations);
    } else {
        for line in text.lines().map(uncommented) {
            found(&LABEL, line, &mut labels);
            found(&BIBITEM, line, &mut citations);
        }
    }
    Symbols { citations, labels }
}

/// A project's labels and citations, and the symbols of each .tex and .bib
/// file by project path, with the file's stamp when it was read: a scan reads
/// again only the files changed since the last, where every save would
/// otherwise read the whole project.
#[derive(Default)]
pub struct SymbolScan(BTreeMap<String, (Stamp, Symbols)>);

impl SymbolScan {
    /// The project's labels and citations. A scan that fails forgets what the
    /// last one read, and the next reads every file.
    pub fn scan(&mut self, root: &Path) -> Result<Symbols, CoreError> {
        let mut known = std::mem::take(&mut self.0);
        let mut files = BTreeMap::new();
        visit_files(root, &mut |abs, rel| {
            let kind = file_kind(rel);
            if kind != "bib" && kind != "tex" {
                return Ok(true);
            }
            // The stamp before the read: a write between them reads again.
            let Some(meta) = skip_unreadable(fs::metadata(abs))? else {
                return Ok(true);
            };
            let stamp = Stamp::of(&meta);
            let symbols = match known.remove(rel) {
                Some((seen, symbols)) if seen == stamp => symbols,
                _ => match skip_unreadable(fs::read(abs))? {
                    Some(bytes) => parse_symbols(&bytes, kind),
                    None => return Ok(true),
                },
            };
            files.insert(rel.to_owned(), (stamp, symbols));
            Ok(true)
        })?;

        fn dedup<'a>(symbols: impl Iterator<Item = &'a String>) -> Vec<String> {
            let mut seen = HashSet::new();
            symbols.filter(|s| seen.insert(*s)).cloned().collect()
        }
        // File-name order keeps completions stable, retaining the first occurrence.
        let found = Symbols {
            citations: dedup(files.values().flat_map(|(_, s)| &s.citations)),
            labels: dedup(files.values().flat_map(|(_, s)| &s.labels)),
        };
        self.0 = files;
        Ok(found)
    }
}

#[cfg(test)]
mod tests {
    use super::SymbolScan;
    use std::fs;

    #[test]
    fn a_scan_reads_again_only_the_files_changed_since() {
        let dir = tempfile::tempdir().unwrap();
        let (root, a) = (dir.path(), dir.path().join("a.tex"));
        fs::write(&a, "\\label{one}").unwrap();
        fs::write(root.join("b.tex"), "\\label{two}").unwrap();
        let mut cache = SymbolScan::default();
        assert_eq!(cache.scan(root).unwrap().labels, ["one", "two"]);
        // Of the same length and date, it is as it was, and isn't read.
        let date = fs::metadata(&a).unwrap().modified().unwrap();
        fs::write(&a, "\\label{uno}").unwrap();
        let file = fs::File::options().write(true).open(&a).unwrap();
        file.set_modified(date).unwrap();
        drop(file);
        fs::write(root.join("b.tex"), "\\label{three}").unwrap();
        fs::write(root.join("c.bib"), "@book{key,").unwrap();
        assert_eq!(cache.scan(root).unwrap().labels, ["one", "three"]);
        fs::remove_file(root.join("b.tex")).unwrap();
        let found = cache.scan(root).unwrap();
        assert_eq!([found.labels, found.citations], [["one"], ["key"]]);
    }

    #[cfg(unix)]
    #[test]
    fn a_scan_reads_through_a_link_whatever_file_it_names() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let (first, second) = (root.join("first.txt"), root.join("second.txt"));
        let link = root.join("link.tex");
        fs::write(&first, "\\label{one}").unwrap();
        fs::write(&second, "\\label{two}").unwrap();
        // Of one length and date: only which file it is tells them apart.
        let date = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        for target in [&first, &second] {
            let file = fs::File::open(target).unwrap();
            file.set_modified(date).unwrap();
        }
        std::os::unix::fs::symlink(&first, &link).unwrap();
        let mut cache = SymbolScan::default();
        assert_eq!(cache.scan(root).unwrap().labels, ["one"]);
        fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(&second, &link).unwrap();
        assert_eq!(cache.scan(root).unwrap().labels, ["two"]);
        // A save of the file it names, as the app writes it, shows through it.
        crate::atomic::write(&second, b"\\label{six}").unwrap();
        assert_eq!(cache.scan(root).unwrap().labels, ["six"]);
    }
}
