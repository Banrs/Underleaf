//! The LaTeX the editors insert and complete (catalog.json, which the web's
//! latex-data.js reads too).

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    /// By id; "$0" marks where the caret goes.
    pub blocks: BTreeMap<String, String>,
    pub environments: Vec<String>,
    pub bib_entry_types: Vec<String>,
    /// (name, detail, snippet); "#{…}" marks a snippet field.
    pub commands: Vec<(String, String, String)>,
}

pub fn get() -> &'static Catalog {
    static CATALOG: OnceLock<Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(include_str!("catalog.json")).expect("catalog.json is valid")
    })
}
