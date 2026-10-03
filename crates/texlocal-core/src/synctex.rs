//! SyncTeX queries: editor line to PDF position, and back.

use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::compile::{run, PROBE_TIMEOUT};
use crate::error::CoreError;
use crate::paths::{rel_to_root, safe_rel_file};
use crate::settings::compiled_pdf_path;
use crate::BUILD_DIR;

// Consume commands, control symbols and comments before matching printed
// characters. Escaped specials print; ordinary grouping braces do not.
static PRINTED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\\(?:\p{Alphabetic}[\p{Alphabetic}@]*|(?P<escaped>[^\s\\])|[\s\\])|%.*|(?P<glyph>[^\s{}\\%])").unwrap()
});

/// Only `page` is required. The rest are omitted when synctex didn't report
/// them, because the PDF viewer falls back with `??` — which fires on an
/// absent field but not on a zero, and a zero-size highlight is invisible.
#[derive(Clone, Debug, Serialize)]
pub struct ForwardLoc {
    pub page: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub h: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub v: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<f64>,
    /// All matching boxes in reading order. The top-level fields retain the
    /// CLI's first match for clients that do not refine a word selection.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub matches: Vec<ForwardLoc>,
}

#[derive(Debug, Serialize)]
pub struct InverseLoc {
    pub file: String,
    pub line: u32,
    /// The clicked letter's place in the line, in UTF-16 units (the hosts'
    /// strings), when the host sent the word and it was found.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
}

fn pdf_for(root: &Path) -> Result<std::path::PathBuf, CoreError> {
    let pdf = compiled_pdf_path(root)?;
    if !pdf.exists() {
        return Err(CoreError::not_found("No compiled PDF yet"));
    }
    Ok(pdf)
}

/// The optional column is zero-based, as in an inverse result. Some TeX
/// engines only record lines, so retain every box even when given a column.
pub async fn synctex_forward_at(
    root: &Path,
    file: &str,
    line: u32,
    column: Option<u32>,
    path_env: &str,
) -> Result<ForwardLoc, CoreError> {
    let pdf = pdf_for(root)?;
    // synctex expects the input path as TeX saw it (relative to cwd,
    // ./-prefixed, forward slashes).
    let rel = safe_rel_file(root, file)?;
    if line < 1 {
        return Err(CoreError::bad_request("Invalid source line"));
    }
    let column = column.unwrap_or(0).saturating_add(1);
    let input = format!("{line}:{column}:./{rel}");
    let pdf_str = pdf.to_string_lossy();
    let (code, stdout) = run(
        "synctex",
        &["view", "-i", &input, "-o", &pdf_str],
        Some(root),
        PROBE_TIMEOUT,
        path_env,
    )
    .await;
    if code != 0 {
        return Err(CoreError::internal("synctex view failed"));
    }
    parse_forward(&stdout)
}

fn parse_forward(stdout: &str) -> Result<ForwardLoc, CoreError> {
    const KEYS: [&str; 7] = ["Page", "x", "y", "h", "v", "W", "H"];
    let mut matches = Vec::new();
    let mut values = [None; 7];
    let finish = |values: [Option<f64>; 7], matches: &mut Vec<ForwardLoc>| {
        let [page, x, y, h, v, width, height] = values;
        if let Some(page) = page.filter(|page| *page >= 1.0) {
            matches.push(ForwardLoc {
                page,
                x,
                y,
                h,
                v,
                width,
                height,
                matches: Vec::new(),
            });
        }
    };
    for ln in stdout.split('\n') {
        let Some((key, value)) = ln.split_once(':') else {
            continue;
        };
        if let Some(i) = KEYS.iter().position(|k| *k == key) {
            if i == 0 {
                finish(std::mem::take(&mut values), &mut matches);
            }
            values[i] = value
                .trim()
                .parse::<f64>()
                .ok()
                .filter(|value| value.is_finite());
        }
    }
    finish(values, &mut matches);
    let mut first = matches
        .first()
        .cloned()
        .ok_or_else(|| CoreError::not_found("No SyncTeX match"))?;
    matches.sort_by(|a, b| {
        a.page
            .total_cmp(&b.page)
            .then_with(|| a.v.unwrap_or(0.0).total_cmp(&b.v.unwrap_or(0.0)))
            .then_with(|| a.h.unwrap_or(0.0).total_cmp(&b.h.unwrap_or(0.0)))
    });
    matches.dedup_by(|a, b| {
        a.page == b.page && a.h == b.h && a.v == b.v && a.width == b.width && a.height == b.height
    });
    first.matches = matches;
    Ok(first)
}

/// PDF location (page, x, y in TeX points from top-left) -> source file:line,
/// and the column of `word`, the word clicked `offset` in, as `find_word` finds it.
pub async fn synctex_inverse(
    root: &Path,
    page: f64,
    x: f64,
    y: f64,
    word: Option<&str>,
    offset: Option<usize>,
    path_env: &str,
) -> Result<InverseLoc, CoreError> {
    synctex_inverse_with_context(root, page, x, y, word, offset, None, None, path_env).await
}

/// PDF context identifies a repeated word by the text on either side of the
/// clicked occurrence. Missing context preserves the line-based lookup.
#[allow(clippy::too_many_arguments)]
pub async fn synctex_inverse_with_context(
    root: &Path,
    page: f64,
    x: f64,
    y: f64,
    word: Option<&str>,
    offset: Option<usize>,
    context: Option<&str>,
    context_offset: Option<usize>,
    path_env: &str,
) -> Result<InverseLoc, CoreError> {
    if !(page.is_finite() && x.is_finite() && y.is_finite()) || page < 1.0 {
        return Err(CoreError::bad_request("Invalid PDF location"));
    }
    let pdf = pdf_for(root)?;
    let target = format!("{page}:{x}:{y}:{}", pdf.to_string_lossy());
    let (code, stdout) = run(
        "synctex",
        &["edit", "-o", &target],
        Some(root),
        PROBE_TIMEOUT,
        path_env,
    )
    .await;
    if code != 0 {
        return Err(CoreError::internal("synctex edit failed"));
    }
    let file = stdout
        .split('\n')
        .find_map(|ln| ln.strip_prefix("Input:"))
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let line = stdout
        .split('\n')
        .find_map(|ln| ln.strip_prefix("Line:"))
        .and_then(|s| s.trim().parse::<u32>().ok());
    let (Some(file), Some(line)) = (file, line) else {
        return Err(CoreError::not_found("No SyncTeX match"));
    };

    let abs = root.join(file);
    // Generated files (.toc/.aux in the build dir) and anything outside the
    // project aren't real sources — report "no match" so the UI shows a toast.
    // TeX records the physical working directory, even if root is a link.
    let no_source = || CoreError::not_found("No source file at this location");
    let canonical_root = std::fs::canonicalize(root)?;
    let rel = rel_to_root(root, &abs)
        .or_else(|| rel_to_root(&canonical_root, &abs))
        // A moved project can retain TeX's old "<folder>/./<file>" spelling.
        .or_else(|| safe_rel_file(root, file.split_once("/./")?.1).ok())
        .ok_or_else(no_source)?;
    let rel = safe_rel_file(root, &rel).map_err(|_| no_source())?;
    let source = std::fs::canonicalize(root.join(&rel)).map_err(|_| no_source())?;
    let physical = rel_to_root(&canonical_root, &source)
        .and_then(|rel| safe_rel_file(root, &rel).ok())
        .ok_or_else(no_source)?;
    // Links within the project can still lead to generated output, and the
    // reserved build name is case-insensitive on every platform.
    if !source.is_file()
        || [&rel, &physical].iter().any(|path| {
            path.split('/')
                .next()
                .is_some_and(|top| top.eq_ignore_ascii_case(BUILD_DIR))
        })
    {
        return Err(no_source());
    }
    let found = word.and_then(|word| {
        let text = crate::lossy_string(std::fs::read(&source).ok()?);
        find_word(
            &text,
            line,
            word,
            offset.unwrap_or(0),
            context.zip(context_offset),
        )
    });
    let (line, column) = found.map_or((line, None), |(line, column)| (line, Some(column)));
    Ok(InverseLoc {
        file: rel,
        line,
        column,
    })
}

/// The clicked letter of `word`, clicked `offset` UTF-16 units in, found in the
/// source as (line, UTF-16 column). SyncTeX records a line, not always the
/// word's own: TeX may be reading a later one as it sets the text. So the
/// word is looked for a few lines either side too, the nearest match winning,
/// earlier first. PDF text runs together words TeX sets close, and spells
/// ligatures as one letter, so the match ignores the source's spaces and line
/// breaks, and needs a word's ends only at its own. A word hyphenated across
/// lines isn't found.
fn find_word(
    text: &str,
    line: u32,
    word: &str,
    offset: usize,
    context: Option<(&str, usize)>,
) -> Option<(u32, u32)> {
    const REACH: u32 = 3;
    const LIGATURES: [(char, &str); 5] = [
        ('ﬀ', "ff"),
        ('ﬁ', "fi"),
        ('ﬂ', "fl"),
        ('ﬃ', "ffi"),
        ('ﬄ', "ffl"),
    ];
    // The word's letters, and how many come before the clicked one.
    let (mut letters, mut clicked, mut units) = (Vec::new(), 0, 0);
    for c in word.chars() {
        if units <= offset {
            clicked = letters.len();
        }
        units += c.len_utf16();
        match LIGATURES.iter().find(|(l, _)| *l == c) {
            Some((_, spelt)) => letters.extend(spelt.chars()),
            None if !c.is_whitespace() => letters.push(c),
            None => {}
        }
    }
    // Without the punctuation round it.
    let lead = letters.iter().take_while(|c| !c.is_alphanumeric()).count();
    let end = letters.iter().rposition(|c| c.is_alphanumeric())? + 1;
    let (letters, clicked) = (&letters[lead..end], clicked.clamp(lead, end - 1) - lead);
    // Printed characters near the recorded line, with their original UTF-16
    // positions and word boundaries. Formatting has no glyphs in the PDF.
    let first = line.saturating_sub(REACH).max(1);
    let mut printed = Vec::new();
    for (text, n) in text
        .lines()
        .zip(1..)
        .skip(first as usize - 1)
        .take_while(|&(_, n)| n <= line.saturating_add(REACH))
    {
        let (mut at, mut column) = (0, 0);
        for token in PRINTED.captures_iter(text) {
            if let Some(glyph) = token.name("escaped").or_else(|| token.name("glyph")) {
                column += text[at..glyph.start()].encode_utf16().count() as u32;
                at = glyph.start();
                let starts_word = text[..at]
                    .chars()
                    .next_back()
                    .is_none_or(|c| !(c.is_alphanumeric() || c == '\\'));
                let ends_word = text[glyph.end()..]
                    .chars()
                    .next()
                    .is_none_or(|c| !c.is_alphanumeric());
                printed.push((
                    (n, column),
                    glyph.as_str().chars().next().unwrap(),
                    starts_word,
                    ends_word,
                ));
            }
        }
    }
    // PDF line-end hyphens are optional: they can be discretionary glyphs
    // (re-\nmain), but a real source hyphen must still match.
    let context = if let Some((text, target)) = context {
        let mut raw = text.chars().peekable();
        let mut previous = '\0';
        let mut normalized = Vec::new();
        let mut start = None;
        let mut units = 0;
        while let Some(c) = raw.next() {
            if units == target {
                start = Some(normalized.len());
            }
            let line_end_hyphen = is_hyphen(c)
                && previous.is_alphabetic()
                && raw.peek().is_some_and(|c| is_line_break(*c))
                && raw
                    .clone()
                    .find(|c| !is_line_break(*c))
                    .is_some_and(|c| c.is_alphabetic());
            previous = c;
            match LIGATURES.iter().find(|(ligature, _)| *ligature == c) {
                Some((_, spelt)) => normalized.extend(spelt.chars().map(|c| (c, false))),
                None if !c.is_whitespace() => normalized.push((c, line_end_hyphen)),
                None => {}
            }
            units += c.len_utf16();
        }
        if units == target {
            start = Some(normalized.len());
        }
        let start = start? + lead;
        let clicked_word = normalized.get(start..start + letters.len())?;
        if !clicked_word
            .iter()
            .map(|(c, _)| *c)
            .eq(letters.iter().copied())
        {
            return None;
        }
        Some((normalized, start))
    } else {
        None
    };
    let score = |k: usize| {
        let Some((context, start)) = &context else {
            return 0;
        };
        let before = matching_context_chars(
            printed[..k].iter().rev().map(|c| c.1),
            context[..*start]
                .iter()
                .rev()
                .map(|&(c, optional)| (c, optional)),
        );
        let end = start + letters.len();
        let after = matching_context_chars(
            printed[k + letters.len()..].iter().map(|c| c.1),
            context[end..].iter().map(|&(c, optional)| (c, optional)),
        );
        before + after
    };
    let mut candidates: Vec<_> = printed
        .windows(letters.len())
        .enumerate()
        .filter(|(_, chars)| {
            chars.iter().map(|c| c.1).eq(letters.iter().copied())
                // Not part of a longer word, nor a command's name.
                && chars[0].2 && chars[chars.len() - 1].3
        })
        .map(|(k, chars)| {
            let (n, column) = chars[clicked].0;
            (
                (std::cmp::Reverse(score(k)), n.abs_diff(line), n > line),
                (n, column),
            )
        })
        .collect();
    candidates.sort_by_key(|c| c.0);
    let (rank, loc) = *candidates.first()?;
    // Ambiguous context must not move the caret to an arbitrary occurrence.
    (context.is_none() || candidates.get(1).is_none_or(|c| c.0 != rank)).then_some(loc)
}

fn is_hyphen(c: char) -> bool {
    matches!(c, '-' | '\u{00ad}' | '\u{2010}' | '\u{2011}')
}

fn is_line_break(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{000c}' | '\u{2028}' | '\u{2029}')
}

fn matching_context_chars(
    source: impl Iterator<Item = char>,
    context: impl Iterator<Item = (char, bool)>,
) -> usize {
    let mut source = source.peekable();
    let mut matched = 0;
    for (context_char, optional_hyphen) in context {
        let Some(&source_char) = source.peek() else {
            break;
        };
        if optional_hyphen && !is_hyphen(source_char) {
            continue;
        }
        if source_char != context_char {
            break;
        }
        source.next();
        matched += 1;
    }
    matched
}

#[cfg(test)]
mod tests {
    use super::{find_word, parse_forward};

    #[test]
    fn forward_keeps_all_boxes_in_page_order_without_changing_the_legacy_match() {
        let output = "Page:2\nh:10\nv:80\nW:100\nH:9\nPage:1\nh:10\nv:60\nW:100\nH:9\nPage:2\nh:10\nv:40\nW:100\nH:9\nPage:2\nh:10\nv:40\nW:100\nH:9\n";
        let result = parse_forward(output).unwrap();
        assert_eq!((result.page, result.v), (2.0, Some(80.0)));
        assert_eq!(
            result
                .matches
                .iter()
                .map(|r| (r.page, r.v))
                .collect::<Vec<_>>(),
            vec![(1.0, Some(60.0)), (2.0, Some(40.0)), (2.0, Some(80.0))]
        );
        assert!(result.matches.iter().all(|r| r.matches.is_empty()));
    }

    #[test]
    fn inverse_uses_context_to_select_each_repeated_word() {
        let source = "echo first, echo second, echo third.";
        for (at, _) in source.match_indices("echo") {
            assert_eq!(
                find_word(source, 1, "echo", 1, Some((source, at))),
                Some((1, at as u32 + 1))
            );
        }
        assert_eq!(
            find_word("echo echo", 1, "echo", 0, Some(("echo", 0))),
            None
        );
    }

    #[test]
    fn inverse_tracks_repeated_sentences_across_pdf_line_wraps() {
        let source = "The same echo repeats. The same echo repeats. The same echo repeats.";
        let pdf = "The same echo\nrepeats. The same\necho repeats. The same echo repeats.";
        for ((source_at, _), (pdf_at, _)) in
            source.match_indices("echo").zip(pdf.match_indices("echo"))
        {
            assert_eq!(
                find_word(source, 1, "echo", 0, Some((pdf, pdf_at))),
                Some((1, source_at as u32))
            );
        }
    }

    #[test]
    fn inverse_context_ignores_formatting_and_preserves_utf16_columns() {
        let source = "🙂 \\emph{echo} first, echo second, \\textbf{echo} third.";
        let pdf = "🙂 echo first, echo second, echo third.";
        for ((source_at, _), (pdf_at, _)) in
            source.match_indices("echo").zip(pdf.match_indices("echo"))
        {
            let source_column = source[..source_at].encode_utf16().count() as u32;
            let pdf_column = pdf[..pdf_at].encode_utf16().count();
            assert_eq!(
                find_word(source, 1, "echo", 0, Some((pdf, pdf_column))),
                Some((1, source_column))
            );
        }
    }

    #[test]
    fn inverse_expands_ligatures_in_context_and_retains_legacy_lookup() {
        let source = "office first, office second.";
        let pdf = "oﬃce first, oﬃce second.";
        let pdf_at = pdf[..pdf.rfind("oﬃce").unwrap()].encode_utf16().count();
        assert_eq!(
            find_word(source, 1, "oﬃce", 1, Some((pdf, pdf_at))),
            Some((1, 15))
        );
        assert_eq!(find_word(source, 1, "office", 1, None), Some((1, 1)));
    }

    #[test]
    fn inverse_matches_discretionary_line_end_hyphen_for_repeated_pdf_words() {
        let sentence = "Native scrolling, selection and zoom should remain responsive.";
        let source_line = format!("{sentence} ").repeat(8);
        let source = format!("{}{}", "\n".repeat(12), source_line);
        let pdf = concat!(
            "2 Section 2\n",
            "Native scrolling, selection and zoom should remain responsive. Native scrolling,\n",
            "selection and zoom should remain responsive. Native scrolling, selection and\n",
            "zoom should remain responsive. Native scrolling, selection and zoom should re-\n",
            "main responsive. Native scrolling, selection and zoom should remain responsive.\n",
            "Native scrolling, selection and zoom should remain responsive. Native scrolling,\n",
            "selection and zoom should remain responsive. Native scrolling, selection and\n",
            "zoom should remain responsive.\n",
            "a2 + b2\n= c2\n3",
        );
        for word in ["Native", "zoom", "responsive"] {
            let source_offsets: Vec<_> =
                source_line.match_indices(word).map(|(at, _)| at).collect();
            let pdf_offsets: Vec<_> = pdf.match_indices(word).map(|(at, _)| at).collect();
            assert_eq!(source_offsets.len(), 8);
            assert_eq!(pdf_offsets.len(), 8);
            for (source_at, pdf_at) in source_offsets.into_iter().zip(pdf_offsets) {
                let clicked_offset = word.encode_utf16().count() / 2;
                let context_offset = pdf[..pdf_at].encode_utf16().count();
                assert_eq!(
                    find_word(
                        &source,
                        13,
                        word,
                        clicked_offset,
                        Some((pdf, context_offset)),
                    ),
                    Some((
                        13,
                        source_line[..source_at].encode_utf16().count() as u32
                            + clicked_offset as u32,
                    )),
                    "wrong {word} mapping at PDF occurrence {context_offset}",
                );
            }
        }
        // The sixth zoom is at context UTF-16 offset 361. A
        // midpoint click must resolve to the sixth source zoom, column 349.
        assert_eq!(
            find_word(&source, 13, "zoom", 2, Some((pdf, 361))),
            Some((13, 349))
        );
    }

    #[test]
    fn inverse_keeps_a_real_hyphen_at_a_line_end_and_rejects_bad_context_ranges() {
        let source = "well-known first. well-known second.";
        let pdf = "well-\nknown first. well-known second.";
        let second = pdf.rfind("second").unwrap();
        assert_eq!(
            find_word(source, 1, "second", 2, Some((pdf, second))),
            Some((1, source.find("second").unwrap() as u32 + 2))
        );
        assert_eq!(
            find_word(source, 1, "second", 2, Some((pdf, pdf.len() + 5))),
            None
        );
        assert_eq!(
            find_word(source, 1, "second", 2, Some(("🙂second", 1))),
            None
        );
    }
}
