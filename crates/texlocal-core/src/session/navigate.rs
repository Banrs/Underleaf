use std::cmp::Reverse;
use std::fs;
use std::path::Path;
use std::sync::{Arc, PoisonError};

use schemars::JsonSchema;
use serde::Serialize;
use texlocal_latex::diff::map_line;
use texlocal_latex::facts::FilePlace;
use texlocal_latex::logparse::{aux_inputs, bad_box, label_number};
use texlocal_latex::search::score;
use texlocal_latex::syntax::catalog::CATALOG;
use texlocal_latex::syntax::{SymbolKind, labelled_lines, sync_lines};
use texlocal_latex::wordmatch::{PdfHit, PdfPage, find_in_pdf};
use texlocal_latex::{bib, project};

use super::Pending;
use super::actor::Actor;
use super::live::{document_lines, typeset_lines};
use super::scans::current_text;
use super::watch::Tree;
use crate::synctex::{self, ForwardLoc, InverseLoc, PageArea, PageClick};
use crate::{CoreError, lossy_string, messages, paths, settings};

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
#[serde(rename_all = "camelCase")]
pub(crate) struct BadBoxArea {
    file: String,
    line: u32,
    // How far an overfull box runs past the text, in points; none for an underfull one.
    too_wide: Option<f64>,
    message: String,
    // Where the box is typeset on one of the pages it's on.
    area: ForwardLoc,
    // How far the lines in the area run past the width TeX set them to, in points.
    overrun: f64,
}

#[derive(Serialize, JsonSchema)]
pub(crate) struct QuickHelp {
    kind: SymbolKind,
    title: String,
    detail: String,
    place: Option<FilePlace>,
    // Where the shown PDF typeset what a label names.
    shown: Option<ForwardLoc>,
}

impl Tree {
    pub fn quick_open(&self, query: String, reply: Pending<Vec<QuickOpenItem>>) {
        let scan = Arc::clone(&self.scan.read().unwrap_or_else(PoisonError::into_inner));
        let (files, main) = (self.files.clone(), self.main.clone());
        reply.spawn(move || {
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
                return Ok(items);
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
            Ok(items.collect())
        });
    }
}

impl Actor {
    pub fn quick_help(&self, path: &str, offset: u32, reply: Pending<Option<QuickHelp>>) {
        let Some(doc) = self.docs.get(path).map(|doc| doc.doc.clone()) else {
            return reply.send(Ok(None));
        };
        let (project, docs) = (self.core.project.clone(), self.docs.handles());
        let settings = settings::read_settings(&project.settings);
        let aux = settings.output(&project.build, "aux");
        let (live, reader) = (self.live.pdf(&self.core), self.core.pdf.synctex.reader());
        let typeset = matches!(live, Ok(Some(_))).then(|| self.live.typeset().clone());
        reply.spawn(move || {
            let root = &project.root;
            let found = doc.with(|source| {
                let (kind, name, _) = source.symbol_at(offset)?;
                let defined = source.defined(kind, &name).into_iter().next();
                Some((kind, name, defined))
            });
            let Some((kind, name, defined)) = found else {
                return Ok(None);
            };
            let text = |file: &str| current_text(&docs, root, file);
            let detail = match (kind, &defined) {
                (SymbolKind::Citation, Some((file, _))) => {
                    let entry = text(file).and_then(|text| bib::entry(&text, &name));
                    Some(entry.unwrap_or_default())
                }
                (SymbolKind::Label, Some(_)) => {
                    let number = aux.ok().and_then(|aux| numbered(&aux, &name));
                    let number = number.unwrap_or_else(|| messages::label_unnumbered().text);
                    let symbols = doc.symbols();
                    let what = symbols.labels().find(|label| label.name == name);
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
                    package.map(|package| messages::from_package(package).text)
                }
                _ => None,
            };
            let shown = match (kind, &defined, live) {
                (SymbolKind::Label, Some((file, at)), Ok(live)) => text(file).and_then(|text| {
                    let mut lines = labelled_lines(&text, at.line);
                    if let Some(typeset) = typeset.as_ref().and_then(|typeset| typeset.get(file)) {
                        let typeset = |line| map_line(typeset, &text, line);
                        lines = typeset(*lines.start())..=typeset(*lines.end());
                    }
                    let sync = reader.of(&project, live.as_deref()).ok()?;
                    let areas = synctex::areas(sync, &project);
                    areas(file, lines).into_iter().next().map(|(area, _)| area)
                }),
                _ => None,
            };
            let place = defined.map(|(file, at)| at.in_file(file));
            Ok(detail.map(|detail| QuickHelp {
                kind,
                title: name,
                detail,
                place,
                shown,
            }))
        });
    }

    pub fn synctex_forward(&self, file: String, line: u32, reply: Pending<ForwardLoc>) {
        if line < 1 {
            return reply.send(Err(CoreError::bad_request(messages::invalid_line())));
        }
        let (live, project) = (self.live.pdf(&self.core), self.core.project.clone());
        let doc = self.docs.get(&file).map(|doc| doc.doc.clone());
        let typeset = matches!(live, Ok(Some(_))).then(|| self.live.typeset().get(&file).cloned());
        let reader = self.core.pdf.synctex.reader();
        reply.spawn(move || {
            let live = live?;
            let typeset = typeset.flatten();
            let lines = match doc {
                Some(doc) => document_lines(&doc, typeset.as_deref(), line),
                None => {
                    let text = lossy_string(fs::read(paths::safe_path(&project.root, &file)?)?);
                    match typeset {
                        Some(typeset) => typeset_lines(&typeset, &text, line),
                        None => sync_lines(&text, line),
                    }
                }
            };
            let sync = reader.of(&project, live.as_deref())?;
            synctex::forward(&sync, &project, &file, &lines)
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
        let (live, project) = (self.live.pdf(&self.core), self.core.project.clone());
        let sources = self.live.typeset().clone();
        let (docs, reader) = (self.docs.handles(), self.core.pdf.synctex.reader());
        reply.spawn(move || {
            let live = live?;
            let typeset = |rel: &str| live.as_ref().and_then(|_| sources.get(rel));
            let text = |rel: &str| typeset(rel).map(ToString::to_string);
            let sync = reader.of(&project, live.as_deref())?;
            let mut loc = synctex::inverse(&sync, &project, page, x, y, click, &text)?;
            // SyncTeX answers in the typeset text's lines, which edits since may have moved.
            if let (Some(typeset), Some(doc)) = (typeset(&loc.file), docs.get(&loc.file)) {
                loc.line = map_line(&doc.snapshot().0, typeset, loc.line);
            }
            Ok(loc)
        });
    }

    /// Where the last build's bad boxes are in its PDF; none while Live Preview's is shown, which has its own lines. A
    /// paragraph can run over pages: an underfull box is marked on each, an overfull one on those where a line runs past
    /// its width, when SyncTeX shows one does.
    pub fn bad_box_areas(&self, reply: Pending<Vec<BadBoxArea>>) {
        if !matches!(self.live.pdf(&self.core), Ok(None)) {
            return reply.send(Ok(Vec::new()));
        }
        let (boxes, project) = (self.builds.bad_boxes().to_vec(), self.core.project.clone());
        let reader = self.core.pdf.synctex.reader();
        reply.spawn(move || {
            let Ok(sync) = reader.of(&project, None) else {
                return Ok(Vec::new());
            };
            let areas = synctex::areas(sync, &project);
            let mut found = Vec::new();
            for item in boxes {
                let (Some(file), Some(line)) = (item.file, item.line) else {
                    continue;
                };
                let Some(bad) = bad_box(&item.message.text) else {
                    continue;
                };
                let mut pages = areas(&file, bad.lines);
                let runs_over = |&(_, overrun): &PageArea| overrun > 0.5;
                if bad.too_wide.is_some() && pages.iter().any(runs_over) {
                    pages.retain(runs_over);
                }
                found.extend(pages.into_iter().map(|(area, overrun)| BadBoxArea {
                    file: file.clone(),
                    line,
                    too_wide: bad.too_wide,
                    message: item.message.text.clone(),
                    area,
                    overrun,
                }));
            }
            Ok(found)
        });
    }

    pub fn synctex_match(
        &self,
        file: String,
        line: u32,
        column: usize,
        pages: Vec<PdfPage>,
        reply: Pending<Option<PdfHit>>,
    ) {
        let doc = self.docs.get(&file).map(|doc| doc.doc.clone());
        let root = self.core.project.root.clone();
        reply.spawn(move || {
            let text = match doc {
                Some(doc) => Ok(doc.with(|source| source.line(line))),
                None => paths::safe_path(&root, &file).and_then(|path| {
                    let text = lossy_string(fs::read(path)?);
                    let index = line.checked_sub(1);
                    Ok(index.and_then(|n| text.lines().nth(n as usize).map(str::to_owned)))
                }),
            };
            text.map(|line| line.and_then(|line| find_in_pdf(&line, column, &pages)))
        });
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
