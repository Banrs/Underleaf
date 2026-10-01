//! The LaTeX the editors insert, complete and recognise (catalog.json, which
//! the web's latex-data.js reads too).

use std::collections::BTreeMap;
use std::sync::LazyLock;

use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    /// By id; "$0" marks where the caret goes.
    pub blocks: BTreeMap<String, String>,
    pub environments: Vec<String>,
    pub bib_entry_types: Vec<String>,
    /// Sectioning commands, outermost first.
    pub sections: Vec<String>,
    pub cite_commands: Vec<String>,
    pub ref_commands: Vec<String>,
    /// Commands whose options and first argument are names, not prose:
    /// classes, packages, environments, labels and files.
    pub name_commands: Vec<String>,
    /// Environments whose body is maths, starred or not.
    pub math_environments: Vec<String>,
    pub verbatim_environments: Vec<String>,
    /// Commands whose braced argument is text, even in maths.
    pub text_commands: Vec<String>,
    /// The maths environments the preview renders.
    pub preview_environments: Vec<String>,
    /// (name, detail, snippet); "#{…}" marks a snippet field.
    pub commands: Vec<(String, String, String)>,
}

pub static CATALOG: LazyLock<Catalog> = LazyLock::new(|| {
    serde_json::from_str(include_str!("catalog.json")).expect("catalog.json is valid")
});

/// A list as a regex alternation: `a|b|c`.
pub fn alternation(names: &[String]) -> String {
    names
        .iter()
        .map(|n| regex::escape(n))
        .collect::<Vec<_>>()
        .join("|")
}
