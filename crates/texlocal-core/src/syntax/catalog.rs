use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    pub blocks: BTreeMap<String, String>,
    pub environments: Vec<String>,
    pub bib_entry_types: Vec<String>,
    pub cite_commands: HashSet<String>,
    pub ref_commands: HashSet<String>,
    pub name_commands: HashSet<String>,
    pub math_environments: HashSet<String>,
    pub verbatim_environments: HashSet<String>,
    pub text_commands: HashSet<String>,
    pub preview_environments: HashSet<String>,
    pub packages: HashMap<String, String>,
    pub commands: Vec<(String, String)>,
    pub templates: Templates,
    pub symbol_groups: Vec<SymbolGroup>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Templates {
    pub math: Vec<Template>,
    pub insert: Vec<Template>,
    pub list: Vec<Template>,
    pub references: Vec<Template>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Template {
    pub title: String,
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symbol: Option<String>,
    #[serde(default)]
    pub inline: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SymbolGroup {
    pub title: String,
    pub symbols: Vec<Symbol>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Symbol {
    pub glyph: String,
    pub command: String,
}

pub static CATALOG: LazyLock<Catalog> = LazyLock::new(|| {
    let mut catalog: Catalog =
        serde_json::from_str(include_str!("catalog.json")).expect("catalog.json is valid");
    let symbols = catalog.symbol_groups.iter().flat_map(|g| &g.symbols);
    let more: Vec<_> = symbols
        .map(|s| s.command.clone())
        .filter(|c| !c.contains('{') && !catalog.commands.iter().any(|(name, _)| name == c))
        .map(|c| (c.clone(), c))
        .collect();
    catalog.commands.extend(more);
    catalog
});
