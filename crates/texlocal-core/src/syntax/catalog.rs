//! The LaTeX the editors insert, complete and recognise (catalog.json).

use std::collections::{BTreeMap, HashSet};
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    /// By id.
    pub blocks: BTreeMap<String, String>,
    pub environments: Vec<String>,
    pub bib_entry_types: Vec<String>,
    pub cite_commands: HashSet<String>,
    pub ref_commands: HashSet<String>,
    /// Commands whose options and first argument are names, not prose:
    /// classes, packages, environments, labels, bibliography keys and files.
    pub name_commands: HashSet<String>,
    /// Environments whose body is maths, starred or not.
    pub math_environments: HashSet<String>,
    pub verbatim_environments: HashSet<String>,
    /// Commands whose braced argument is text, even in maths.
    pub text_commands: HashSet<String>,
    /// The maths environments the preview renders.
    pub preview_environments: HashSet<String>,
    /// (name, snippet); "#{…}" marks a snippet field.
    pub commands: Vec<(String, String)>,
    pub templates: Templates,
    /// The levels a line's style can be, outermost first: indexed by the
    /// outline's depth.
    pub heading_levels: Vec<HeadingLevel>,
    /// The maths symbols by kind, each inserted as its command.
    pub symbol_groups: Vec<SymbolGroup>,
}

/// What the toolbar and the Insert, Format and Math menus put in.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Templates {
    pub math: Vec<Template>,
    pub insert: Vec<Template>,
    pub list: Vec<Template>,
    /// Cross-references, citations and links; with nothing selected, a
    /// reference or citation offers what can go in its braces.
    pub references: Vec<Template>,
}

/// A block of `blocks` by its id, or with `inline` a command with "$0" for
/// the selection (the "wrap" command's template). `symbol` names the SF
/// Symbol the Mac's toolbar shows it by, which makes it a toolbar button.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Template {
    pub title: String,
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
    #[serde(default)]
    pub inline: bool,
}

/// A sectioning command (without its backslash) and its name.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HeadingLevel {
    pub title: String,
    pub command: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SymbolGroup {
    pub title: String,
    pub symbols: Vec<Symbol>,
}

/// A symbol as Unicode has it, and the command that sets it.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Symbol {
    pub glyph: String,
    pub command: String,
}

pub static CATALOG: LazyLock<Catalog> = LazyLock::new(|| {
    serde_json::from_str(include_str!("catalog.json")).expect("catalog.json is valid")
});
