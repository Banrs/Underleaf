use std::collections::HashSet;
use std::sync::LazyLock;

use regex::{Captures, Regex};
use serde::{Deserialize, Serialize, Serializer};
use serde_json::json;

use crate::syntax::catalog::CATALOG;
use crate::syntax::scan::closing_brace;

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, Hash)]
pub struct LogItem {
    #[serde(rename = "type")]
    pub kind: Severity,
    pub file: Option<String>,
    pub line: Option<u32>,
    pub message: String,
    #[serde(skip)]
    pub short: String,
    #[serde(skip)]
    pub command: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) explain: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix: Option<Fix>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Deserialize)]
#[serde(try_from = "String")]
pub enum Fix {
    Install(String),
    AddPackage(String),
    Xelatex,
    ShellEscape,
}

impl TryFrom<String> for Fix {
    type Error = &'static str;

    fn try_from(id: String) -> Result<Self, Self::Error> {
        match id.split_once(':') {
            Some(("install", file)) => Ok(Self::Install(file.into())),
            Some(("package", name)) => Ok(Self::AddPackage(name.into())),
            Some(("engine", "xelatex")) => Ok(Self::Xelatex),
            None if id == "shellEscape" => Ok(Self::ShellEscape),
            _ => Err("There's no such fix."),
        }
    }
}

impl Serialize for Fix {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Install(file) => json!({
                "id": format!("install:{file}"),
                "title": "Install",
                "help": format!("Installs the TeX Live package that has {file}, then compiles again."),
            }),
            Self::AddPackage(name) => json!({
                "id": format!("package:{name}"),
                "title": format!("Add \\usepackage{{{name}}}"),
                "help": format!("Loads {name} in the main file's preamble, then compiles again."),
            }),
            Self::Xelatex => json!({
                "id": "engine:xelatex",
                "title": "Use XeLaTeX",
                "help": "Compiles the project with XeLaTeX from now on, which takes any Unicode character and the computer's own fonts.",
            }),
            Self::ShellEscape => json!({
                "id": "shellEscape",
                "title": "Turn On Shell Escape",
                "help": "Lets the project's packages run programs as it compiles, then compiles again.",
                "confirm": "Shell Escape lets this document run programs on your computer as it compiles. Turn it on only for documents you trust.",
            }),
        }
        .serialize(serializer)
    }
}

impl LogItem {
    pub(crate) fn new(
        kind: Severity,
        file: Option<String>,
        line: Option<u32>,
        message: String,
    ) -> Self {
        let flat = message.split_whitespace().collect::<Vec<_>>().join(" ");
        let short = flat
            .strip_prefix("LaTeX Error: ")
            .unwrap_or(&flat)
            .to_owned();
        let command = undefined_command(&short);
        let (explain, fix) = explained(&short, command.as_deref());
        Self {
            kind,
            file,
            line,
            message,
            command,
            explain,
            fix,
            short,
        }
    }

    pub fn error(message: impl Into<String>) -> Self {
        Self::new(Severity::Error, None, None, message.into())
    }

    fn shell_escape(file: Option<String>, line: Option<u32>) -> Self {
        let message = SHELL_ESCAPE.into();
        let fix = Some(Fix::ShellEscape);
        Self {
            fix,
            ..Self::new(Severity::Error, file, line, message)
        }
    }
}

fn undefined_command(message: &str) -> Option<String> {
    let name = message.strip_prefix("Undefined control sequence: \\")?;
    let letters = name.chars().all(|c| c.is_ascii_alphabetic() || c == '@');
    ((!name.is_empty() && letters) || name.chars().count() == 1).then(|| format!("\\{name}"))
}

#[derive(Clone, Copy)]
enum Offer {
    Nothing,
    Install,
    Package,
    Xelatex,
}

static EXPLAINED: LazyLock<Vec<(Regex, Offer, &str)>> = LazyLock::new(|| {
    use Offer::{Install, Nothing, Package, Xelatex};
    [
        (
            r"File `([^`'/\\\s]+\.(?:sty|cls))' not found\.",
            Install,
            "This package or class isn't installed in your TeX distribution. Install it, then compile again.",
        ),
        (
            r"File `[^`']*' not found",
            Nothing,
            "TeX can't find this file. Check its name and folder, written from the main file's folder, and that the file is in the project.",
        ),
        (
            r"Undefined control sequence",
            Package,
            "TeX doesn't know this command. Check its spelling, or load the package that defines it in the preamble.",
        ),
        (
            r"^Environment (\S+) undefined",
            Package,
            "LaTeX doesn't know this environment. Check its spelling, or load the package that defines it in the preamble.",
        ),
        (
            r"Missing \$ inserted",
            Nothing,
            "Something only maths may hold, such as ^, _ or a Greek letter, is outside maths, or a blank line breaks an equation. Put it between $ signs, or remove the blank line.",
        ),
        (
            r"Extra \}, or forgotten|Too many \}'s",
            Nothing,
            "A closing brace has no opening one to match, or maths was left open before it. Look for a } too many, or a $ missing, on this line or just before it.",
        ),
        (
            r"Missing \} inserted",
            Nothing,
            "A group was still open where TeX needed it closed: a { without its }, or maths left open. Look for the brace or $ missing on this line or just before it.",
        ),
        (
            r"Runaway argument|Paragraph ended before \S+ was complete|File ended while scanning use of",
            Nothing,
            "A command's argument runs on into a blank line or the end of the file, usually because its closing brace is missing. Close the brace where the argument should end.",
        ),
        (
            r"Misplaced alignment tab character",
            Nothing,
            r"An & is outside a table or aligned equation, where it only separates columns. Write \& for an ampersand in text.",
        ),
        (
            r"Extra alignment tab has been changed",
            Nothing,
            "A row has more & than its table has columns. Add a column to the table's definition, or remove an & from the row.",
        ),
        (
            r"\\begin\{[^}]*\} on input line \d+ ended by \\end",
            Nothing,
            r"An environment is closed by another's \end, or one inside it was left open. Make each \end name its \begin's environment, closing the inner ones first.",
        ),
        (
            r"Missing \\begin\{document\}",
            Nothing,
            r"Something that typesets comes before \begin{document}, where only the preamble's settings may go. Move it below \begin{document}, or look for a stray character in the preamble.",
        ),
        (
            r"Can be used only in preamble",
            Nothing,
            r"This command only works before \begin{document}. Move it to the preamble.",
        ),
        (
            r"There's no line here to end",
            Nothing,
            r"A \\ or \newline comes where no line has begun, such as at a paragraph's start or after a heading. Remove it, or use \vspace for space between paragraphs.",
        ),
        (
            r"Option clash for package",
            Nothing,
            r"The package is loaded twice with different options, perhaps once by the class or another package. Load it once with all its options, or give them earlier with \PassOptionsToPackage.",
        ),
        (
            r"Emergency stop|no legal \\end found",
            Nothing,
            r"TeX stopped here and couldn't go on, often because the file ends before \end{document} or an earlier error left it nothing to read. Fix the first error above this one, and check that the main file ends with \end{document}.",
        ),
        (
            r"^Citation .* undefined",
            Nothing,
            r"No bibliography entry or \bibitem has this key. Check its spelling against the .bib file's, and that the document names that file with \bibliography or \addbibresource.",
        ),
        (
            r"Unicode character .* not set up for use with LaTeX",
            Xelatex,
            "pdfLaTeX's fonts have no letter for this character. XeLaTeX typesets it with a font that has one; or write it as a LaTeX command.",
        ),
        (
            r"requires (?:either )?XeTeX|Cannot be run with pdfLaTeX",
            Xelatex,
            "This package needs XeLaTeX or LuaLaTeX, and the project compiles with pdfLaTeX. Compile it with XeLaTeX.",
        ),
        (
            r"Command \\\S+ already defined",
            Nothing,
            r"\newcommand names a command that exists already, perhaps one a package defines. Choose another name, or use \renewcommand to replace it.",
        ),
    ]
    .into_iter()
    .map(|(pattern, offer, explain)| (Regex::new(pattern).unwrap(), offer, explain))
    .collect()
});

fn explained(short: &str, command: Option<&str>) -> (Option<&'static str>, Option<Fix>) {
    let Some((found, offer, explain)) = EXPLAINED
        .iter()
        .find_map(|(pattern, offer, explain)| Some((pattern.captures(short)?, *offer, *explain)))
    else {
        return (None, None);
    };
    let named = || found.get(1).map(|name| name.as_str().to_owned());
    let fix = match offer {
        Offer::Nothing => None,
        Offer::Install => named().map(Fix::Install),
        Offer::Package => (command.map(str::to_owned).or_else(named))
            .and_then(|name| CATALOG.packages.get(&name).cloned())
            .map(Fix::AddPackage),
        Offer::Xelatex => Some(Fix::Xelatex),
    };
    (Some(explain), fix)
}

static ERROR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^(?:(?P<file>(?:[A-Za-z]:)?[^\s:!][^:]*):(?P<line>\d+):(?:\s+|$)|! )(?P<message>.*)$",
    )
    .unwrap()
});
static L_NO: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^l\.(\d+)").unwrap());
static LAST_CS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\\(?:[A-Za-z@]+|.))\s*$").unwrap());
static WARNING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:LaTeX(?: Font| NFSS)?|Package \S+|Class \S+) Warning:\s*(?P<message>.*)$")
        .unwrap()
});
static ON_LINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"on input line (\d+)").unwrap());
static BAD_BOX_LINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:at lines|detected at line) (\d+)").unwrap());
static BIBTEX_ERROR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(.*)---line (\d+) of file (.+)$").unwrap());
static BIBTEX_WARNING_PLACE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^--line (\d+) of file (.+)$").unwrap());
static BIBER_MESSAGE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[\d+\] .*> (ERROR|WARN) - (.*)$").unwrap());
static SHELL_ESCAPE_ASKED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)shell[- ]escape|\\write18").unwrap());
static RUNSYSTEM_REFUSED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"runsystem\(.*\)\.\.\.disabled").unwrap());

fn error_start(line: &str) -> Option<Captures<'_>> {
    ERROR
        .captures(line)
        .filter(|m| m.name("file").is_none_or(|f| is_path(f.as_str())))
}

fn is_path(text: &str) -> bool {
    text.contains(['/', '\\']) || (text.contains('.') && !text.contains(char::is_whitespace))
}

fn warning_start(line: &str) -> Option<Captures<'_>> {
    line.contains(" Warning:")
        .then(|| WARNING.captures(line))
        .flatten()
}

fn project_path(path: &str) -> Option<String> {
    let absolute = match path.as_bytes() {
        [b'/' | b'\\', ..] => true,
        [drive, b':', b'/' | b'\\', ..] => drive.is_ascii_alphabetic(),
        _ => false,
    };
    (!absolute).then(|| path.strip_prefix("./").unwrap_or(path).to_string())
}

fn opens_file(token: &str) -> bool {
    token.contains('/')
        || match token.as_bytes() {
            [drive, b':', b'\\', ..] => drive.is_ascii_alphabetic(),
            [b'\\', b'\\', ..] => token[2..].contains('\\'),
            _ => false,
        }
}

fn named_file(token: &str) -> bool {
    token.rsplit_once('.').is_some_and(|(stem, ext)| {
        !stem.is_empty() && !ext.is_empty() && ext.bytes().all(|b| b.is_ascii_alphabetic())
    })
}

fn track<'a>(open: &mut Vec<Option<&'a str>>, line: &'a str, opens: &dyn Fn(&str) -> bool) {
    let mut rest = line;
    while let Some(i) = rest.find(['(', ')']) {
        let paren = rest.as_bytes()[i];
        rest = &rest[i + 1..];
        if paren == b')' {
            open.pop();
            continue;
        }
        let (token, after) = match rest.strip_prefix('"') {
            Some(quoted) => quoted.split_once('"').unwrap_or((quoted, "")),
            None => rest.split_at(
                rest.find(|c: char| c.is_whitespace() || c == '(' || c == ')')
                    .unwrap_or(rest.len()),
            ),
        };
        open.push(opens(token).then_some(token));
        rest = after;
    }
}

fn locate(
    named: Option<&str>,
    line: Option<u32>,
    open: &[Option<&str>],
    main_file: &str,
    message: &mut String,
    project: &dyn Fn(&str) -> Option<String>,
) -> (Option<String>, Option<u32>) {
    let Some(line) = line else {
        return (None, None);
    };
    let mut files = open.iter().rev().flatten().copied();
    let Some(path) = named.or_else(|| files.clone().next()) else {
        return (Some(main_file.to_string()), Some(line));
    };
    if let Some(rel) = project(path) {
        return (Some(rel), Some(line));
    }
    let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
    *message = format!("{name}: {message}");
    (files.find_map(project), None)
}

fn continuation_tag(text: &str) -> Option<&str> {
    let mut words = text.split_whitespace();
    match (words.next()?, words.next()?) {
        ("Package" | "Class", name) => Some(name),
        ("LaTeX", "Font") => Some("Font"),
        ("LaTeX", word) if word.ends_with(':') => Some("LaTeX"),
        _ => None,
    }
}

fn starts_new(line: &str) -> bool {
    line.trim().is_empty()
        || line.starts_with(['!', '<'])
        || L_NO.is_match(line)
        || error_start(line).is_some()
        || warning_start(line).is_some()
}

fn continuation<'a>(
    prev: &str,
    next: &'a str,
    tag: Option<&str>,
) -> Option<(&'a str, &'static str)> {
    let tagged = tag.and_then(|tag| next.strip_prefix('(')?.strip_prefix(tag)?.strip_prefix(')'));
    if let Some(rest) = tagged {
        Some((rest.trim(), " "))
    } else if prev.chars().count() == 79 && !next.starts_with('(') {
        Some((next, ""))
    } else {
        next.starts_with([' ', '\t']).then(|| (next.trim(), " "))
    }
}

fn blank_from(lines: &[&str], from: usize) -> usize {
    (from..lines.len())
        .find(|&j| lines[j].trim().is_empty())
        .unwrap_or(lines.len())
}

fn echo_of(lines: &[&str], i: usize) -> Option<usize> {
    lines[i + 1..(i + 12).min(lines.len())]
        .iter()
        .take_while(|next| !next.starts_with('!') && error_start(next).is_none())
        .position(|next| L_NO.is_match(next))
        .map(|k| i + 1 + k)
}

pub fn parse_log(log: &str, main_file: &str) -> (Vec<LogItem>, Vec<LogItem>) {
    parse(log, main_file, None)
}

type Ours<'a> = &'a dyn Fn(&str) -> Option<String>;

pub fn parse_live_log(log: &str, main_file: &str, ours: Ours) -> Vec<LogItem> {
    let (items, _) = parse(log, main_file, Some(ours));
    items
        .into_iter()
        .filter(|item| item.kind == Severity::Error)
        .collect()
}

struct Diagnostic<'a> {
    named: Option<&'a str>,
    error: bool,
    message: String,
    line: Option<u32>,
    echo: Option<usize>,
    summary: bool,
}

fn diagnostic<'a>(lines: &[&str], i: usize, m: &Captures<'a>) -> Diagnostic<'a> {
    let named = m.name("file").map(|m| m.as_str());
    let error = named.is_some() || lines[i].starts_with("! ");
    let mut message = m["message"].to_string();
    let echo = if error { echo_of(lines, i) } else { None };
    let tag = continuation_tag(if error { &m["message"] } else { lines[i] });
    let mut prev = lines[i];
    for next in lines[i + 1..].iter().take_while(|next| !starts_new(next)) {
        let Some((text, joiner)) = continuation(prev, next, tag) else {
            break;
        };
        if !text.is_empty() {
            if !joiner.is_empty() {
                message.truncate(message.trim_end().len());
            }
            message.push_str(joiner);
            message.push_str(text);
        }
        prev = next;
    }
    let summary = error && message.trim_start().starts_with("==>");
    if message
        .trim_start()
        .starts_with("Undefined control sequence.")
        && let Some(j) = echo
        && let Some(m) = lines[i + 1..=j].iter().find_map(|l| LAST_CS.captures(l))
    {
        message = format!("Undefined control sequence: {}", &m[1]);
    }
    let line = if summary && named.is_some() {
        None
    } else if error {
        m.name("line")
            .or_else(|| echo.and_then(|j| L_NO.captures(lines[j])?.get(1)))
            .and_then(|line| line.as_str().parse().ok())
    } else {
        ON_LINE.captures(&message).and_then(|lm| lm[1].parse().ok())
    };
    Diagnostic {
        named,
        error,
        message,
        line,
        echo,
        summary,
    }
}

fn parse(log: &str, main_file: &str, ours: Option<Ours>) -> (Vec<LogItem>, Vec<LogItem>) {
    let opens = |token: &str| opens_file(token) || ours.is_some() && named_file(token);
    let project = |path: &str| ours.map_or_else(|| project_path(path), |ours| ours(path));
    let lines: Vec<&str> = log.lines().collect();
    let mut items: Vec<LogItem> = Vec::new();
    let mut bad_boxes = Vec::new();
    let mut open = Vec::new();
    let mut quiet_until = 0;

    for (i, &line) in lines.iter().enumerate() {
        let may_err = line.starts_with("! ") || line.contains(':');
        let start = may_err
            .then(|| error_start(line))
            .flatten()
            .or_else(|| warning_start(line));
        if let Some(m) = start {
            let mut found = diagnostic(&lines, i, &m);
            if found.error {
                quiet_until = (found.echo).map_or_else(|| blank_from(&lines, i + 1), |j| j + 2);
            }
            if found.summary && items.iter().any(|item| item.kind == Severity::Error) {
                continue;
            }
            let message = &mut found.message;
            let (file, line_no) =
                locate(found.named, found.line, &open, main_file, message, &project);
            let kind = if found.error {
                Severity::Error
            } else {
                Severity::Warning
            };
            items.push(LogItem::new(
                kind,
                file,
                line_no,
                found.message.trim().into(),
            ));
        } else if line.starts_with("Overfull \\") || line.starts_with("Underfull \\") {
            quiet_until = blank_from(&lines, i + 1);
            let line_no = BAD_BOX_LINE.captures(line).and_then(|m| m[1].parse().ok());
            let mut message = line.trim().to_string();
            let (file, line_no) = locate(None, line_no, &open, main_file, &mut message, &project);
            bad_boxes.push(LogItem::new(Severity::Warning, file, line_no, message));
        }
        if i >= quiet_until {
            track(&mut open, line, &opens);
        }
    }

    let mut seen = HashSet::new();
    items.retain(|item| seen.insert(item.clone()));
    bad_boxes.retain(|item| seen.insert(item.clone()));
    (items, bad_boxes)
}

pub fn parse_blg(blg: &str) -> Vec<LogItem> {
    let mut items: Vec<LogItem> = Vec::new();
    let mut above = "";
    for line in blg.lines() {
        if let Some(m) = BIBTEX_ERROR.captures(line) {
            let file = project_path(m[3].trim());
            let message = if m[1].trim().is_empty() { above } else { &m[1] };
            items.push(LogItem::new(
                Severity::Error,
                file.clone(),
                file.and(m[2].parse().ok()),
                message.trim().to_string(),
            ));
        } else if let Some(message) = line.strip_prefix("Warning--") {
            items.push(LogItem::new(
                Severity::Warning,
                None,
                None,
                message.trim().to_string(),
            ));
        } else if let Some(m) = BIBTEX_WARNING_PLACE.captures(line)
            && above.starts_with("Warning--")
            && let Some(warning) = items.last_mut()
        {
            warning.file = project_path(m[2].trim());
            warning.line = warning.file.as_ref().and(m[1].parse().ok());
        } else if let Some(m) = BIBER_MESSAGE.captures(line) {
            let kind = if &m[1] == "WARN" {
                Severity::Warning
            } else {
                Severity::Error
            };
            items.push(LogItem::new(kind, None, None, m[2].trim().to_string()));
        }
        above = line;
    }
    items
}

const SHELL_ESCAPE: &str = "A package here runs programs as it builds, which needs Shell Escape. Turn on Shell Escape in the project's settings if you trust the project.";

pub fn point_to_shell_escape(errors: &mut Vec<LogItem>, log: &str) {
    if let Some(error) = errors
        .iter_mut()
        .find(|e| SHELL_ESCAPE_ASKED.is_match(&e.short))
    {
        *error = LogItem::shell_escape(error.file.take(), error.line);
    } else if RUNSYSTEM_REFUSED.is_match(log) {
        errors.insert(0, LogItem::shell_escape(None, None));
    }
}

pub fn latexmk_errors(output: &str) -> Vec<LogItem> {
    output
        .lines()
        .skip_while(|line| !line.starts_with("Collected error summary"))
        .skip(1)
        .take_while(|line| line.starts_with("  "))
        .filter(|line| !line.starts_with("   "))
        .map(|line| LogItem::error(line.trim()))
        .collect()
}

pub fn label_number(aux: &str, label: &str) -> Option<String> {
    let key = format!("\\newlabel{{{label}}}{{{{");
    let number = &aux[aux.find(&key)? + key.len()..];
    let end = closing_brace(number)?;
    let page = number[end + 1..].strip_prefix('{')?;
    let page = &page[..closing_brace(page)?];
    Some(format!("{} on page {page}", &number[..end]))
}

pub fn aux_inputs(aux: &str) -> impl Iterator<Item = &str> {
    let inputs = aux.split("\\@input{").skip(1);
    inputs.filter_map(|rest| rest.get(..rest.find('}')?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn errors(log: &str) -> Vec<LogItem> {
        let (items, _) = parse_log(log, "main.tex");
        items
            .into_iter()
            .filter(|i| i.kind == Severity::Error)
            .collect()
    }

    fn warnings(log: &str) -> Vec<LogItem> {
        let (items, _) = parse_log(log, "main.tex");
        items
            .into_iter()
            .filter(|i| i.kind == Severity::Warning)
            .collect()
    }

    #[test]
    fn an_error_names_its_file_and_line() {
        let log = "(./main.tex\n(./chapters/intro.tex\n./chapters/intro.tex:12: Undefined control sequence.\nl.12 \\foo\n          \n)\n)";
        let found = errors(log);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].file.as_deref(), Some("chapters/intro.tex"));
        assert_eq!(found[0].line, Some(12));
        assert!(found[0].message.contains("Undefined control sequence"));
    }

    #[test]
    fn a_missing_package_offers_to_install_it() {
        let log = "(./main.tex\n./main.tex:3: LaTeX Error: File `fancyfoo.sty' not found.\n\nType X to quit or <RETURN> to proceed,\nl.3 \\usepackage{fancyfoo}\n)";
        let found = errors(log);
        assert_eq!(found[0].line, Some(3));
        assert_eq!(found[0].fix, Some(Fix::Install("fancyfoo.sty".into())));
        assert!(found[0].explain.is_some());
    }

    #[test]
    fn a_command_a_known_package_defines_offers_that_package() {
        let log = "(./main.tex\n./main.tex:8: Undefined control sequence.\nl.8 \\toprule\n)";
        assert_eq!(errors(log)[0].fix, Some(Fix::AddPackage("booktabs".into())));
    }

    #[test]
    fn a_character_pdflatex_lacks_offers_xelatex() {
        let log = "(./main.tex\n./main.tex:5: LaTeX Error: Unicode character ✓ (U+2713)\n               not set up for use with LaTeX.\nl.5 ✓\n)";
        assert_eq!(errors(log)[0].fix, Some(Fix::Xelatex));
    }

    #[test]
    fn undefined_references_and_citations_are_warnings_on_their_lines() {
        let log = "(./main.tex\nLaTeX Warning: Reference `fig:x' on page 1 undefined on input line 7.\n\nLaTeX Warning: Citation `knuth' on page 1 undefined on input line 9.\n)";
        let found = warnings(log);
        assert_eq!(found.len(), 2);
        assert_eq!(
            (found[0].file.as_deref(), found[0].line),
            (Some("main.tex"), Some(7))
        );
        assert_eq!(found[1].line, Some(9));
    }

    #[test]
    fn overfull_boxes_are_kept_apart_from_the_issues() {
        let log = "(./main.tex\nOverfull \\hbox (12.0pt too wide) in paragraph at lines 5--6\n[]\\OT1/cmr/m/n/10 text\n)";
        let (items, bad_boxes) = parse_log(log, "main.tex");
        assert!(items.is_empty());
        assert_eq!(bad_boxes.len(), 1);
        assert_eq!(bad_boxes[0].line, Some(5));
    }

    #[test]
    fn a_clean_log_has_nothing() {
        let log = "This is pdfTeX, Version 3.141592653\n(./main.tex\nLaTeX2e <2025-11-01>\n) [1]\nOutput written on main.pdf (1 page, 1234 bytes).";
        let (items, bad_boxes) = parse_log(log, "main.tex");
        assert!(items.is_empty() && bad_boxes.is_empty());
    }

    #[test]
    fn bibtex_reports_missing_entries() {
        let blg = "Warning--I didn't find a database entry for \"knuth\"\n";
        let found = parse_blg(blg);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, Severity::Warning);
        assert!(found[0].message.contains("knuth"));
    }

    #[test]
    fn biber_errors_are_errors() {
        let blg = "[12] Biber.pm:131> ERROR - Cannot find 'refs.bib'!\n";
        assert_eq!(parse_blg(blg)[0].kind, Severity::Error);
    }

    #[test]
    fn latexmk_summarises_what_failed() {
        let output = "Latexmk: Errors, so I did not complete making targets\nCollected error summary (may duplicate other messages):\n  pdflatex: Command for 'pdflatex' gave return code 1\n      Refer to 'main.log' for details\n";
        let found = latexmk_errors(output);
        assert_eq!(found.len(), 1);
        assert!(found[0].message.starts_with("pdflatex: Command"));
    }

    #[test]
    fn shell_escape_refused_says_how_to_turn_it_on() {
        let mut found = Vec::new();
        point_to_shell_escape(&mut found, "runsystem(pygmentize -V)...disabled.");
        assert_eq!(found[0].message, SHELL_ESCAPE);
    }

    #[test]
    fn a_fix_id_round_trips() {
        for id in [
            "install:foo.sty",
            "package:booktabs",
            "engine:xelatex",
            "shellEscape",
        ] {
            let fix = Fix::try_from(id.to_owned()).unwrap();
            assert_eq!(serde_json::to_value(&fix).unwrap()["id"], id);
        }
        assert!(Fix::try_from("format:disk".to_owned()).is_err());
    }
}
