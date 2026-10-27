use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::LazyLock;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    pub(crate) blocks: BTreeMap<String, String>,
    pub(crate) environments: Vec<String>,
    pub(crate) bib_entry_types: Vec<String>,
    pub(crate) cite_commands: HashSet<String>,
    pub(crate) ref_commands: HashSet<String>,
    pub(crate) name_commands: HashSet<String>,
    pub(crate) math_environments: HashSet<String>,
    pub(crate) verbatim_environments: HashSet<String>,
    pub(crate) text_commands: HashSet<String>,
    pub(crate) preview_environments: HashSet<String>,
    pub packages: HashMap<String, String>,
    pub(crate) commands: Vec<(String, String)>,
    pub(crate) templates: Templates,
    pub(crate) symbol_groups: Vec<SymbolGroup>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema)]
pub(crate) struct Templates {
    pub(crate) math: Vec<Template>,
    pub(crate) insert: Vec<Template>,
    pub(crate) list: Vec<Template>,
    pub(crate) references: Vec<Template>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema)]
pub(crate) struct Template {
    pub(crate) title: String,
    pub(crate) body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) symbol: Option<String>,
    #[serde(default)]
    pub(crate) inline: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema)]
pub(crate) struct SymbolGroup {
    pub(crate) title: String,
    pub(crate) symbols: Vec<Symbol>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema)]
pub(crate) struct Symbol {
    pub(crate) glyph: String,
    pub(crate) command: String,
}

#[derive(Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Menus {
    templates: &'static Templates,
    symbol_groups: &'static [SymbolGroup],
}

pub(crate) fn menus() -> Menus {
    Menus {
        templates: &CATALOG.templates,
        symbol_groups: &CATALOG.symbol_groups,
    }
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
