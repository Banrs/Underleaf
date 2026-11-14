//! Citations fetched by DOI or arXiv identifier: where to ask, and the entry laid out for a project's `.bib`.

use std::sync::LazyLock;

use regex::Regex;
use schemars::JsonSchema;
use serde::Serialize;

use crate::bib::{entries, field, fields, raw_fields, surnames};
use crate::percent_encoded;

#[derive(Debug, PartialEq, Eq, Serialize, JsonSchema)]
pub struct CitationSource {
    pub id: String,
    pub url: String,
    pub accept: String,
}

static DOI: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?i)\b(10\.\d{4,9}/[^\s"<>]+)"#).unwrap());
static ESCAPED_TWICE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"%25([0-9a-fA-F]{2})").unwrap());
static ARXIV: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:arxiv:\s*|https?://(?:www\.)?arxiv\.org/(?:abs|pdf)/)?(\d{4}\.\d{4,5}|[a-z-]+(?:\.[a-z]{2})?/\d{7})(?:v\d+)?(?:\.pdf)?/?$").unwrap()
});

/// Where to fetch BibTeX for a DOI or an arXiv identifier, given bare or as a link.
pub fn citation_source(text: &str) -> Option<CitationSource> {
    let text = text.trim();
    if let Some(found) = ARXIV.captures(text) {
        let id = found[1].to_owned();
        let url = format!("https://arxiv.org/bibtex/{id}");
        return Some(CitationSource {
            id,
            url,
            accept: "text/plain".into(),
        });
    }
    let found = DOI.find(text)?;
    let mut doi = found.as_str();
    let in_url = text[..found.start()]
        .rsplit(|c: char| c.is_whitespace() || "\"<>".contains(c))
        .next()
        .is_some_and(|token| token.contains("://"));
    if in_url {
        doi = doi.split(['?', '#']).next().unwrap();
    }
    // Punctuation after a DOI in prose, but not a bracket the DOI opened, as in `10.1002/(SICI)1097-4636(199907)`.
    loop {
        let unopened = |close: char, open: char| {
            doi.ends_with(close) && doi.matches(close).count() > doi.matches(open).count()
        };
        if doi.ends_with(['.', ',', ';']) || unopened(')', '(') || unopened(']', '[') {
            doi = &doi[..doi.len() - 1];
        } else {
            break;
        }
    }
    let mut encoded = percent_encoded(doi.as_bytes());
    if in_url {
        encoded = ESCAPED_TWICE.replace_all(&encoded, "%$1").into_owned();
    }
    Some(CitationSource {
        id: doi.to_owned(),
        url: format!("https://doi.org/{encoded}"),
        accept: "application/x-bibtex; charset=utf-8".into(),
    })
}

#[derive(Debug, PartialEq, Eq)]
pub struct Tidied {
    pub key: String,
    pub entry: String,
    pub doi: Option<String>,
    pub eprint: Option<String>,
}

const FIRST: [&str; 15] = [
    "author",
    "title",
    "journal",
    "booktitle",
    "publisher",
    "volume",
    "number",
    "pages",
    "year",
    "month",
    "doi",
    "url",
    "eprint",
    "archiveprefix",
    "primaryclass",
];

/// The first entry of fetched BibTeX, one field a line, keyed by its first author's surname, its year and its title's
/// first word, as Google Scholar keys them (`einstein1905does`), with a letter added while `taken` says the key is used.
pub fn tidy(source: &str, taken: impl Fn(&str) -> bool) -> Option<Tidied> {
    let (entry, body) = entries(source).next()?;
    let kind = entry[1].to_ascii_lowercase();
    let mut raw = raw_fields(body);
    raw.sort_by_key(|(name, _)| {
        FIRST
            .iter()
            .position(|first| name.eq_ignore_ascii_case(first))
            .unwrap_or(FIRST.len())
    });
    let parsed = fields(body);
    let field = |name: &str| field(&parsed, name).map(|value| value.trim().to_owned());
    let surname = surnames(&parsed).first().map(|surname| ascii_word(surname));
    let year = field("year").or_else(|| field("date")).and_then(|year| {
        year.get(..4)
            .filter(|year| year.bytes().all(|b| b.is_ascii_digit()))
            .map(str::to_owned)
    });
    let word = field("title").and_then(|title| {
        let words = title
            .split(|c: char| c.is_whitespace() || c == '-')
            .map(ascii_word);
        words
            .filter(|word| !word.is_empty())
            .find(|word| !STOP_WORDS.contains(&word.as_str()))
    });
    let made = [surname, year, word]
        .into_iter()
        .flatten()
        .collect::<String>();
    let base = [made, ascii_key(&entry[2])]
        .into_iter()
        .find(|base| !base.is_empty())
        .unwrap_or_else(|| "ref".into());
    let key = std::iter::once(base.clone())
        .chain((b'a'..=b'z').map(|letter| format!("{base}{}", char::from(letter))))
        .chain((2..).map(|n| format!("{base}{n}")))
        .find(|key| !taken(key))
        .expect("a free key");
    let lines: Vec<String> = raw
        .iter()
        .map(|(name, at)| format!("  {name} = {}", &body[at.clone()]))
        .collect();
    let entry = format!("@{kind}{{{key},\n{}\n}}\n", lines.join(",\n"));
    Some(Tidied {
        key,
        entry,
        doi: field("doi"),
        eprint: field("eprint"),
    })
}

/// The key of an entry in `source` with the same DOI, ignoring case, or the same arXiv identifier, ignoring version.
pub fn find_entry(source: &str, doi: Option<&str>, eprint: Option<&str>) -> Option<String> {
    let bare = |id: &str| {
        let id = id.trim().to_ascii_lowercase();
        match id.rsplit_once('v') {
            Some((bare, version))
                if !version.is_empty() && version.bytes().all(|b| b.is_ascii_digit()) =>
            {
                bare.to_owned()
            }
            _ => id,
        }
    };
    entries(source).find_map(|(entry, body)| {
        let fields = fields(body);
        let field = |name: &str| field(&fields, name).map(|value| value.trim().to_owned());
        let same_doi = doi
            .zip(field("doi"))
            .is_some_and(|(a, b)| a.eq_ignore_ascii_case(&b));
        let same_eprint = eprint
            .zip(field("eprint"))
            .is_some_and(|(a, b)| bare(a) == bare(&b));
        (same_doi || same_eprint).then(|| entry[2].to_owned())
    })
}

const STOP_WORDS: [&str; 15] = [
    "a", "an", "the", "on", "of", "in", "for", "and", "to", "with", "from", "at", "by", "is", "are",
];

/// Lower-case ASCII letters, with accents dropped, whether written as TeX (`{\"o}`) or as Unicode (`ö`).
fn ascii_word(text: &str) -> String {
    let mut word = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            let mut name = String::new();
            while let Some(&next) = chars.peek().filter(|c| c.is_ascii_alphabetic()) {
                name.push(next);
                chars.next();
            }
            if name.is_empty() {
                chars.next();
            }
            word.push_str(match name.as_str() {
                "o" | "O" => "o",
                "ss" => "ss",
                "l" | "L" => "l",
                "aa" | "AA" => "a",
                "ae" | "AE" => "ae",
                "oe" | "OE" => "oe",
                _ => "",
            });
        } else {
            word.push_str(&fold(c));
        }
    }
    word
}

fn ascii_key(key: &str) -> String {
    key.chars()
        .filter(|c| c.is_ascii_alphanumeric() || "-_:.".contains(*c))
        .collect()
}

fn fold(c: char) -> String {
    if c.is_ascii_alphanumeric() {
        return c.to_ascii_lowercase().to_string();
    }
    let folded = match c.to_lowercase().next().unwrap_or(c) {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
        'ç' | 'ć' | 'č' => "c",
        'ď' | 'đ' => "d",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ė' | 'ę' | 'ě' => "e",
        'ğ' => "g",
        'ì' | 'í' | 'î' | 'ï' | 'ī' | 'ı' => "i",
        'ł' => "l",
        'ñ' | 'ń' | 'ň' => "n",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ő' => "o",
        'ŕ' | 'ř' => "r",
        'ś' | 'š' | 'ş' | 'ș' => "s",
        'ť' | 'ţ' | 'ț' => "t",
        'ù' | 'ú' | 'û' | 'ü' | 'ů' | 'ū' | 'ű' => "u",
        'ý' | 'ÿ' => "y",
        'ź' | 'ż' | 'ž' => "z",
        'ß' => "ss",
        'æ' => "ae",
        'œ' => "oe",
        _ => "",
    };
    folded.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_doi_or_arxiv_identifier_is_found_bare_or_in_a_link() {
        let doi = |text| citation_source(text).map(|found| (found.id, found.url));
        let arxiv = |text: &str| citation_source(text).map(|found| found.url);
        assert_eq!(
            doi("https://doi.org/10.1103/PhysRevLett.116.061102."),
            Some((
                "10.1103/PhysRevLett.116.061102".into(),
                "https://doi.org/10.1103/PhysRevLett.116.061102".into()
            ))
        );
        assert_eq!(doi("doi:10.1000/a<b>c").unwrap().0, "10.1000/a");
        assert_eq!(
            doi("10.1002/(SICI)1097-4636").unwrap().1,
            "https://doi.org/10.1002/%28SICI%291097-4636"
        );
        let url = "https://doi.org/10.1000/a%28b%29";
        assert_eq!(doi(url).unwrap().1, url);
        assert_eq!(
            doi("10.1000/a%28b%29").unwrap().1,
            "https://doi.org/10.1000/a%2528b%2529"
        );
        for id in [
            "1706.03762",
            "arXiv:1706.03762v5",
            "https://arxiv.org/abs/1706.03762",
            "https://arxiv.org/pdf/1706.03762v2.pdf",
        ] {
            assert_eq!(
                arxiv(id).as_deref(),
                Some("https://arxiv.org/bibtex/1706.03762"),
                "{id}"
            );
        }
        assert_eq!(
            arxiv("hep-th/9901001").as_deref(),
            Some("https://arxiv.org/bibtex/hep-th/9901001")
        );
        assert_eq!(
            arxiv("math.GT/0309136").as_deref(),
            Some("https://arxiv.org/bibtex/math.GT/0309136")
        );
        for nothing in ["", "hello", "1706", "see 1706.03762 here"] {
            assert_eq!(citation_source(nothing), None, "{nothing}");
        }
    }

    const CROSSREF: &str = " @article{Abbott_2016, title={Observation of {Gravitational} Waves}, volume={116}, \
        DOI={10.1103/physrevlett.116.061102}, number={6}, journal={Physical Review Letters}, \
        author={Abbott, B. P. and Abbott, R.}, year={2016}, month=feb, pages={061102} }";

    #[test]
    fn a_fetched_entry_is_keyed_and_laid_out_one_field_a_line() {
        let tidied = tidy(CROSSREF, |_| false).unwrap();
        assert_eq!(tidied.key, "abbott2016observation");
        assert_eq!(
            tidied.doi.as_deref(),
            Some("10.1103/physrevlett.116.061102")
        );
        assert_eq!(
            tidied.entry,
            "@article{abbott2016observation,\n  author = {Abbott, B. P. and Abbott, R.},\n  \
             title = {Observation of {Gravitational} Waves},\n  journal = {Physical Review Letters},\n  \
             volume = {116},\n  number = {6},\n  pages = {061102},\n  year = {2016},\n  month = feb,\n  \
             DOI = {10.1103/physrevlett.116.061102}\n}\n"
        );
        let taken = ["abbott2016observation", "abbott2016observationa"];
        assert_eq!(
            tidy(CROSSREF, |key| taken.contains(&key)).unwrap().key,
            "abbott2016observationb"
        );
    }

    #[test]
    fn a_parenthesized_entry_loses_only_its_closing_parenthesis() {
        let tidied = tidy("@misc(k,title={X})", |_| false).unwrap();
        assert_eq!(tidied.entry, "@misc{x,\n  title = {X}\n}\n");
        assert_eq!(crate::bib::entry(&tidied.entry, "x").as_deref(), Some("X"));
    }

    #[test]
    fn a_key_drops_accents_and_skips_a_titles_small_first_words() {
        let arxiv = "@misc{x2023, title={The {\\\"O}rsted Effect}, author={Ashish {\\\"O}rsted and Noam Shazeer}, \
                     year={2023}, eprint={1706.03762}, archivePrefix={arXiv}}";
        let tidied = tidy(arxiv, |_| false).unwrap();
        assert_eq!(tidied.key, "orsted2023orsted");
        assert_eq!(tidied.eprint.as_deref(), Some("1706.03762"));
        let unicode = "@book{k, author={Gödel, Kurt}, title={On Formally Undecidable Propositions}, year={1931}}";
        assert_eq!(tidy(unicode, |_| false).unwrap().key, "godel1931formally");
        let wrapped = "@book{k, author={Donald Knuth\nand Leslie Lamport}, title={Literate Programming}, year={1984}}";
        assert_eq!(tidy(wrapped, |_| false).unwrap().key, "knuth1984literate");
        let bare = "@misc{Some_Key:1, howpublished={x}}";
        assert_eq!(tidy(bare, |_| false).unwrap().key, "Some_Key:1");
        assert_eq!(tidy("no entry", |_| false), None);
    }

    #[test]
    fn an_entry_already_cited_is_found_by_doi_or_arxiv_identifier() {
        let bib = "@article{mine, doi = {10.1103/PhysRevLett.116.061102}}\n@misc{other, eprint = {1706.03762v2}}\n\
                   @misc{old, eprint = {solv-int/9901001}}";
        assert_eq!(
            find_entry(bib, Some("10.1103/physrevlett.116.061102"), None).as_deref(),
            Some("mine")
        );
        assert_eq!(
            find_entry(bib, None, Some("1706.03762")).as_deref(),
            Some("other")
        );
        assert_eq!(
            find_entry(bib, None, Some("solv-int/9901001v1")).as_deref(),
            Some("old")
        );
        assert_eq!(find_entry(bib, Some("10.1/x"), Some("1111.11111")), None);
    }
}
