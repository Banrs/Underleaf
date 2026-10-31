use std::sync::LazyLock;

use regex::Regex;

use crate::syntax::headings::{SPACES, plain_title};

static BIB_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"@([0-9A-Za-z_]+)\s*[{(]\s*([^,\s]+)\s*,").unwrap());
pub(crate) static CROSSREF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?i)(?:^|,)\s*crossref\s*=\s*[{"]?\s*([^\s,{}"]+)"#).unwrap());

pub(crate) fn entries(source: &str) -> impl Iterator<Item = (regex::Captures<'_>, &str)> {
    let mut found = BIB_KEY.captures_iter(source).peekable();
    std::iter::from_fn(move || {
        let entry = found.next()?;
        let next = found
            .peek()
            .map_or(source.len(), |next| next.get_match().start());
        let body = &source[entry.get_match().end()..next];
        Some((entry, body))
    })
}

pub(crate) fn fields(body: &str) -> Vec<(String, String)> {
    let (mut fields, mut name, mut value) = (Vec::new(), String::new(), None::<String>);
    let (mut depth, mut quoted) = (0_usize, false);
    for c in body.chars() {
        let top = depth == 0 && !quoted;
        match (c, value.as_mut()) {
            ('}' | ')', _) if top => break,
            (',', _) if top => {
                fields.extend(value.take().map(|value| (name.clone(), value)));
                name.clear();
            }
            ('=', None) => value = Some(String::new()),
            (c, None) if !c.is_whitespace() => name.push(c.to_ascii_lowercase()),
            (_, None) => {}
            ('"', Some(_)) if depth == 0 => quoted = !quoted,
            ('{', Some(text)) => {
                if !top {
                    text.push(c);
                }
                depth += 1;
            }
            ('}', Some(text)) => {
                depth = depth.saturating_sub(1);
                if depth > 0 || quoted {
                    text.push(c);
                }
            }
            (c, Some(_)) if top && (c == '#' || c.is_whitespace()) => {}
            (c, Some(text)) => text.push(c),
        }
    }
    fields.extend(value.map(|value| (name, value)));
    fields
}

fn field<'a>(fields: &'a [(String, String)], name: &str) -> Option<&'a str> {
    let (_, value) = fields.iter().find(|(n, _)| n == name)?;
    Some(value)
}

fn authors(fields: &[(String, String)], name: impl Fn(&str) -> Option<String>) -> Vec<String> {
    let Some(authors) = field(fields, "author") else {
        return Vec::new();
    };
    let authors = SPACES.replace_all(authors, " ");
    parted(&authors, " and ")
        .into_iter()
        .filter_map(name)
        .collect()
}

fn year(fields: &[(String, String)]) -> Option<String> {
    let date = || field(fields, "date").and_then(|date| date.get(..4));
    field(fields, "year").or_else(date).and_then(plain_title)
}

pub(crate) fn detail(fields: &[(String, String)]) -> Option<String> {
    let field = |name| field(fields, name);
    let last = |name: &str| {
        let name = name.trim();
        let last = match parted(name, ",").as_slice() {
            [last, _, ..] => *last,
            _ => *parted(name, " ").last().expect("a part at least"),
        };
        plain_title(last)
    };
    let authors = match authors(fields, last).as_slice() {
        [] => None,
        [one] => Some(one.clone()),
        [one, two] => Some(format!("{one} and {two}")),
        [one, ..] => Some(format!("{one} et al.")),
    };
    let parts = [authors, year(fields), field("title").and_then(plain_title)];
    let parts: Vec<String> = parts.into_iter().flatten().collect();
    (!parts.is_empty()).then(|| parts.join(" · "))
}

pub fn entry(source: &str, key: &str) -> Option<String> {
    let (_, body) = entries(source).find(|(entry, _)| &entry[2] == key)?;
    let fields = fields(body);
    let field = |name| field(&fields, name);
    let author = |name: &str| match parted(name.trim(), ",").as_slice() {
        [last, first, ..] => plain_title(&format!("{first} {last}")),
        _ => plain_title(name),
    };
    let authors = authors(&fields, author).join(", ");
    let published = ["journal", "publisher", "booktitle"]
        .into_iter()
        .find_map(field);
    let lines = [
        Some(authors).filter(|authors| !authors.is_empty()),
        field("title").and_then(plain_title),
        year(&fields),
        published.and_then(plain_title),
    ];
    Some(lines.into_iter().flatten().collect::<Vec<_>>().join("\n"))
}

fn parted<'a>(text: &'a str, at: &str) -> Vec<&'a str> {
    let (mut parts, mut depth, mut from) = (Vec::new(), 0_usize, 0);
    for (i, c) in text.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => depth = depth.saturating_sub(1),
            _ if depth == 0
                && i >= from
                && text
                    .get(i..i + at.len())
                    .is_some_and(|s| s.eq_ignore_ascii_case(at)) =>
            {
                parts.push(&text[from..i]);
                from = i + at.len();
            }
            _ => {}
        }
    }
    parts.push(&text[from..]);
    parts
}
