use std::cmp::Reverse;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, PoisonError};

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::facts::FilePlace;
use texlocal_latex::logparse::{aux_inputs, label_number};
use texlocal_latex::search::score;
use texlocal_latex::syntax::SymbolKind;
use texlocal_latex::syntax::catalog::CATALOG;
use texlocal_latex::wordmatch::{PdfHit, PdfPage, find_in_pdf};
use texlocal_latex::{bib, project};

use super::Pending;
use super::actor::Actor;
use crate::synctex::{self, ForwardLoc, InverseLoc, PageClick};
use crate::{CoreError, lf, lock, lossy_string, paths, settings};

const LISTED: usize = 50;

#[derive(Serialize, JsonSchema)]
pub(crate) struct QuickOpenItem {
    kind: QuickOpenKind,
    title: String,
    detail: String,
    path: String,
    line: Option<u32>,
}

#[derive(PartialEq, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) enum QuickOpenKind {
    File,
    Heading,
    Label,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct QuickHelp {
    title: String,
    detail: String,
    place: Option<FilePlace>,
}

impl Actor {
    pub fn quick_open(&self, query: String, reply: Pending<Vec<QuickOpenItem>>) {
        let scan = Arc::clone(&self.scan.read().unwrap_or_else(PoisonError::into_inner));
        let (files, main) = (self.tree.files.clone(), self.tree.main.clone());
        tokio::task::spawn_blocking(move || {
            let mut items: Vec<QuickOpenItem> = files
                .into_iter()
                .map(|path| {
                    let (folder, name) = path.rsplit_once('/').unwrap_or(("", &path));
                    QuickOpenItem {
                        kind: QuickOpenKind::File,
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
                return reply.send(Ok(items));
            }
            if let Some(main) = main {
                let analysis = project::analyze(&scan, Some(&main), None);
                items.extend(analysis.outline.into_iter().map(|heading| {
                    let path = heading.file;
                    QuickOpenItem {
                        kind: QuickOpenKind::Heading,
                        detail: format!("{} · {path}", heading.level),
                        title: heading.title,
                        line: Some(heading.line as u32),
                        path,
                    }
                }));
                for file in analysis.files {
                    let Some(facts) = scan.facts.get(&file) else {
                        continue;
                    };
                    items.extend(facts.defined.labels.iter().map(|label| QuickOpenItem {
                        kind: QuickOpenKind::Label,
                        title: label.name.clone(),
                        detail: label.detail.clone().unwrap_or_default(),
                        path: file.clone(),
                        line: Some(label.place.line),
                    }));
                }
            }
            let mut scored: Vec<(Reverse<i64>, usize, QuickOpenItem)> = items
                .into_iter()
                .filter_map(|item| {
                    let text = if item.kind == QuickOpenKind::File {
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
            reply.send(Ok(items.collect()));
        });
    }

    pub fn quick_help(&self, path: &str, offset: u32, reply: Pending<Option<QuickHelp>>) {
        let Some(doc) = self.docs.get(path).map(|doc| doc.doc.clone()) else {
            return reply.send(Ok(None));
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
                return reply.send(Ok(None));
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
                    let entry = text(file).and_then(|text| bib::entry(&text, &name));
                    Some(entry.unwrap_or_default())
                }
                (SymbolKind::Label, Some(_)) => {
                    let number = aux.ok().and_then(|aux| numbered(&aux, &name));
                    let number = number.unwrap_or_else(|| "Compile to number it".to_owned());
                    let symbols = doc.symbols();
                    let mut labels = own.defined.labels.iter().chain(symbols.labels());
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
            let place = defined.map(|(file, at)| at.in_file(file));
            reply.send(Ok(detail.map(|detail| QuickHelp {
                title: name,
                detail,
                place,
            })));
        });
    }
}

impl Actor {
    fn live_pdf(&self) -> Result<Option<PathBuf>, CoreError> {
        let shown = self.live.active() && self.live.document_seen;
        shown.then(|| self.preview.live_pdf(self.id)).transpose()
    }

    pub fn synctex_forward(&self, file: String, line: u32, reply: Pending<ForwardLoc>) {
        let (live, project) = (self.live_pdf(), self.project.clone());
        tokio::task::spawn_blocking(move || {
            reply.send(
                live.and_then(|live| synctex::forward(&project, &file, line, live.as_deref())),
            );
        });
    }

    pub fn synctex_inverse(
        &self,
        page: f64,
        x: f64,
        y: f64,
        click: Option<PageClick>,
        reply: Pending<InverseLoc>,
    ) {
        let (live, project) = (self.live_pdf(), self.project.clone());
        let (preview, id) = (Arc::clone(&self.preview), self.id);
        tokio::task::spawn_blocking(move || {
            reply.send(live.and_then(|live| {
                let typeset = |rel: &str| live.as_ref().and_then(|_| preview.live_text(id, rel));
                synctex::inverse(&project, page, x, y, click, live.as_deref(), &typeset)
            }));
        });
    }

    pub fn synctex_match(
        &self,
        file: &str,
        line: u32,
        column: usize,
        pages: &[PdfPage],
    ) -> Result<Option<PdfHit>, CoreError> {
        let text = match self.docs.get(file) {
            Some(doc) => doc.doc.snapshot().0,
            None => lossy_string(fs::read(paths::safe_path(&self.project.root, file)?)?),
        };
        let line = line
            .checked_sub(1)
            .and_then(|n| text.lines().nth(n as usize));
        Ok(line.and_then(|line| find_in_pdf(line, column, pages)))
    }
}

fn numbered(aux: &Path, label: &str) -> Option<String> {
    let main = fs::read_to_string(aux).ok()?;
    label_number(&main, label).or_else(|| {
        let folder = aux.parent()?;
        aux_inputs(&main).find_map(|input| {
            let included = paths::safe_path(folder, input).ok()?;
            label_number(&fs::read_to_string(included).ok()?, label)
        })
    })
}
