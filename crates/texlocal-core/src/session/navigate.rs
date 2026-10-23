//! Moving about a project: the places Back and Forward go to, Open Quickly's list and Quick
//! Help's answer.

use std::cmp::Reverse;
use std::fs;
use std::path::Path;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Reply;
use super::actor::Actor;
use crate::analyze;
use crate::paths;
use crate::service::{arg, out};
use crate::settings;
use crate::syntax::SymbolKind;
use crate::syntax::catalog::CATALOG;
use crate::syntax::scan::closing_brace;
use crate::{CoreError, lf, lock, lossy_string};

/// Back's places, and Forward's, kept at most.
const KEPT: usize = 50;
/// Open Quickly's items at most.
const LISTED: usize = 50;
/// What a character matched at a word's start scores, and one just after the last matched.
const WORD_START: i64 = 8;
const RUN: i64 = 4;

/// A line, from 1, of a project's file.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Place {
    path: String,
    line: u32,
}

/// Where jumps left the caret, the latest last.
#[derive(Default)]
pub(crate) struct Trail {
    back: Vec<Place>,
    forward: Vec<Place>,
}

impl Trail {
    pub fn moved(&mut self, from: &str, to: &str) {
        for place in self.back.iter_mut().chain(&mut self.forward) {
            if let Some(rest) = paths::after_entry(&place.path, from) {
                place.path = format!("{to}{rest}");
            }
        }
    }
}

fn push(places: &mut Vec<Place>, place: Place) {
    if places.last() != Some(&place) {
        places.push(place);
    }
    if places.len() > KEPT {
        places.remove(0);
    }
}

fn place(args: &Value, key: &str) -> Result<Place, CoreError> {
    let place: Place = arg(args, key)?;
    let path = paths::rel_key(&place.path)?;
    Ok(Place { path, ..place })
}

fn exists(root: &Path, place: &Place) -> bool {
    paths::safe_path(root, &place.path).is_ok_and(|path| path.is_file())
}

/// One of Open Quickly's items.
#[derive(Serialize)]
struct Item {
    kind: &'static str,
    title: String,
    detail: String,
    path: String,
    line: Option<u32>,
}

impl Actor {
    pub fn navigate(&mut self, args: &Value) -> Result<Value, CoreError> {
        push(&mut self.trail.back, place(args, "from")?);
        self.trail.forward.clear();
        Ok(self.trail_state())
    }

    /// Back, or Forward: the latest place whose file is there still and that isn't the caret's,
    /// those passed over dropped, with the caret's place kept for the other way.
    pub fn step(&mut self, args: &Value, back: bool) -> Result<Value, CoreError> {
        let at = place(args, "at")?;
        let (root, trail) = (&self.project.root, &mut self.trail);
        let (from, other) = if back {
            (&mut trail.back, &mut trail.forward)
        } else {
            (&mut trail.forward, &mut trail.back)
        };
        let to =
            std::iter::from_fn(|| from.pop()).find(|place| *place != at && exists(root, place));
        if to.is_some() {
            push(other, at);
        }
        let mut answer = self.trail_state();
        answer["to"] = json!(to);
        Ok(answer)
    }

    fn trail_state(&self) -> Value {
        let any = |places: &[Place]| places.iter().any(|p| exists(&self.project.root, p));
        json!({ "back": any(&self.trail.back), "forward": any(&self.trail.forward) })
    }

    /// Worked out beside the session, as a search is: the outline reads the files the main file
    /// reaches.
    pub fn quick_open(&self, query: String, reply: Reply) {
        let (root, facts) = (self.project.root.clone(), Arc::clone(&self.facts));
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
                let analysis = analyze::analyze_project(&root, &facts, &main, &main, None);
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
                    let Some(facts) = facts.at(&root, &file) else {
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
                    // A file by its path, so its folder's name finds it too.
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

    /// What the name at `offset` in the open document `path` is, worked out beside the session,
    /// as usages are: a definition may be in a file only the disk has.
    pub fn quick_help(&self, path: &str, offset: u32, reply: Reply) {
        let Some(doc) = self.docs.get(path).map(|doc| doc.doc.clone()) else {
            return reply.send(Ok(Value::Null));
        };
        let (root, docs) = (self.project.root.clone(), Arc::clone(&self.shared));
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
            // The open document as edited, else the disk's.
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
            let place = defined.map(|(path, at)| Place {
                path,
                line: at.line,
            });
            let help =
                detail.map(|detail| json!({ "title": name, "detail": detail, "place": place }));
            reply.send(Ok(help.unwrap_or(Value::Null)));
        });
    }
}

/// A label's number and page, `3 on page 2`, as a build's .aux has them
/// (`\newlabel{label}{{3}{2}…}`), or as the .aux of a file it `\include`s has them: LaTeX writes
/// that file's labels apart, and the main .aux reads them (`\@input{ch.aux}`).
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

/// How well `query` matches `text`: its characters in order, in any case, each scoring more at
/// a word's start (after / - _ : . or a space, or where lower case turns upper) and just after
/// the last; None where they aren't all there.
fn score(query: &str, text: &str) -> Option<i64> {
    let lower = |c: char| c.to_lowercase().next().unwrap_or(c);
    let text: Vec<char> = text.chars().collect();
    let word_start = |at: usize| {
        at == 0
            || "/-_:. ".contains(text[at - 1])
            || text[at - 1].is_lowercase() && text[at].is_uppercase()
    };
    // The best score with the query so far matched and its last character at each place.
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
