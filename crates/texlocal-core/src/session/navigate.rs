use std::cmp::Reverse;
use std::fs;
use std::path::Path;
use std::sync::{Arc, PoisonError};

use serde::Serialize;
use serde_json::{Value, json};
use texlocal_latex::analyze;
use texlocal_latex::syntax::SymbolKind;
use texlocal_latex::syntax::catalog::CATALOG;
use texlocal_latex::syntax::scan::closing_brace;

use super::Reply;
use super::actor::Actor;
use crate::paths;
use crate::service::out;
use crate::settings;
use crate::{lf, lock, lossy_string};

const LISTED: usize = 50;
const WORD_START: i64 = 8;
const RUN: i64 = 4;

#[derive(Serialize)]
struct Item {
    kind: &'static str,
    title: String,
    detail: String,
    path: String,
    line: Option<u32>,
}

impl Actor {
    pub fn quick_open(&self, query: String, reply: Reply) {
        let symbols = Arc::clone(&self.symbols.read().unwrap_or_else(PoisonError::into_inner));
        let (files, main) = (self.tree.files.clone(), self.tree.main.clone());
        tokio::task::spawn_blocking(move || {
            let mut items: Vec<Item> = files
                .into_iter()
                .map(|path| {
                    let (folder, name) = path.rsplit_once('/').unwrap_or(("", &path));
                    Item {
                        kind: "file",
                        title: name.to_owned(),
                        detail: folder.to_owned(),
                        line: None,
                        path,
                    }
                })
                .collect();
            if query.is_empty() {
                items.sort_unstable_by(|a, b| a.path.cmp(&b.path));
                items.truncate(LISTED);
                return reply.send(out(items));
            }
            if let Some(main) = main {
                let analysis = analyze::analyze_project(&symbols, Some(&main), None);
                items.extend(analysis.outline.into_iter().map(|heading| {
                    let path = heading.file.unwrap_or_default();
                    Item {
                        kind: "heading",
                        detail: format!("{} · {path}", heading.level),
                        title: heading.title,
                        line: Some(heading.line as u32),
                        path,
                    }
                }));
                for file in analysis.files {
                    let Some(facts) = symbols.by_file.get(&file) else {
                        continue;
                    };
                    items.extend(facts.labels.iter().map(|label| Item {
                        kind: "label",
                        title: label.name.clone(),
                        detail: label.detail.clone().unwrap_or_default(),
                        path: file.clone(),
                        line: Some(label.place.line),
                    }));
                }
            }
            let mut scored: Vec<(Reverse<i64>, usize, Item)> = items
                .into_iter()
                .filter_map(|item| {
                    let text = if item.kind == "file" {
                        &item.path
                    } else {
                        &item.title
                    };
                    let (score, length) = (score(&query, text)?, text.chars().count());
                    Some((Reverse(score), length, item))
                })
                .collect();
            scored.sort_by(|(a, a_length, a_item), (b, b_length, b_item)| {
                let a = (a, a_length, &a_item.path, a_item.line);
                a.cmp(&(b, b_length, &b_item.path, b_item.line))
            });
            let items = scored.into_iter().take(LISTED).map(|(.., item)| item);
            reply.send(out(items.collect::<Vec<_>>()));
        });
    }

    pub fn quick_help(&self, path: &str, offset: u32, reply: Reply) {
        let Some(doc) = self.docs.get(path).map(|doc| doc.doc.clone()) else {
            return reply.send(Ok(Value::Null));
        };
        let (root, docs) = (self.project.root.clone(), self.docs.shared());
        let settings = settings::read_settings(&self.project.settings);
        let aux = settings.output(&self.project.build, "aux");
        tokio::task::spawn_blocking(move || {
            let own = doc.facts();
            let found = doc.with(|source| {
                let (kind, name, _) = source.symbol_at(&own, offset)?;
                let defined = source.defined(&own, kind, &name).into_iter().next();
                Some((kind, name, defined))
            });
            let Some((kind, name, defined)) = found else {
                return reply.send(Ok(Value::Null));
            };
            let text = |file: &str| {
                let open = lock(&docs).get(file).cloned();
                match open {
                    Some(doc) => Some(doc.snapshot().0),
                    None => {
                        let abs = paths::safe_path(&root, file).ok()?;
                        fs::read(abs).ok().map(|bytes| lf(lossy_string(bytes)))
                    }
                }
            };
            let detail = match (kind, &defined) {
                (SymbolKind::Citation, Some((file, _))) => {
                    let entry = text(file).and_then(|text| analyze::bib_entry(&text, &name));
                    Some(entry.unwrap_or_default())
                }
                (SymbolKind::Label, Some(_)) => {
                    let number = aux.ok().and_then(|aux| numbered(&aux, &name));
                    let number = number.unwrap_or_else(|| "Compile to number it".to_owned());
                    let symbols = doc.symbols();
                    let mut labels = own.labels.iter().chain(&symbols.labels);
                    let what = labels.find(|label| label.name == name);
                    Some(match what.and_then(|label| label.detail.as_ref()) {
                        Some(what) => format!("{number}\n{what}"),
                        None => number,
                    })
                }
                (SymbolKind::Command, Some((file, at))) => {
                    let text = text(file);
                    let line = text
                        .as_deref()
                        .and_then(|text| text.lines().nth(at.line as usize - 1));
                    line.map(|line| line.trim().to_owned())
                }
                (SymbolKind::Command, None) => {
                    let package = CATALOG.packages.get(&name);
                    package.map(|package| format!("From the {package} package"))
                }
                _ => None,
            };
            let place = defined.map(|(file, at)| {
                json!({ "file": file, "line": at.line, "column": at.column, "length": at.length })
            });
            let help =
                detail.map(|detail| json!({ "title": name, "detail": detail, "place": place }));
            reply.send(Ok(help.unwrap_or(Value::Null)));
        });
    }
}

fn numbered(aux: &Path, label: &str) -> Option<String> {
    let key = format!("\\newlabel{{{label}}}{{{{");
    let find = |aux: &str| {
        let number = &aux[aux.find(&key)? + key.len()..];
        let end = closing_brace(number)?;
        let page = number[end + 1..].strip_prefix('{')?;
        let page = &page[..closing_brace(page)?];
        Some(format!("{} on page {page}", &number[..end]))
    };
    let main = fs::read_to_string(aux).ok()?;
    find(&main).or_else(|| {
        let folder = aux.parent()?;
        main.split("\\@input{").skip(1).find_map(|rest| {
            let included = paths::safe_path(folder, &rest[..rest.find('}')?]).ok()?;
            find(&fs::read_to_string(included).ok()?)
        })
    })
}

fn score(query: &str, text: &str) -> Option<i64> {
    let lower = |c: char| c.to_lowercase().next().unwrap_or(c);
    let text: Vec<char> = text.chars().collect();
    let word_start = |at: usize| {
        at == 0
            || "/-_:. ".contains(text[at - 1])
            || text[at - 1].is_lowercase() && text[at].is_uppercase()
    };
    let mut best: Vec<Option<i64>> = Vec::new();
    for (i, wanted) in query.chars().map(lower).enumerate() {
        let mut earlier = None;
        let mut next = vec![None; text.len()];
        for (at, &c) in text.iter().enumerate() {
            if lower(c) == wanted {
                let bonus = if word_start(at) { WORD_START } else { 0 };
                let before = match i {
                    0 => Some(0),
                    _ => {
                        let run = at.checked_sub(1).and_then(|k| best[k]).map(|s| s + RUN);
                        run.max(earlier)
                    }
                };
                next[at] = before.map(|score| score + bonus);
            }
            if i > 0 {
                earlier = earlier.max(best[at]);
            }
        }
        best = next;
    }
    best.into_iter().flatten().max()
}
