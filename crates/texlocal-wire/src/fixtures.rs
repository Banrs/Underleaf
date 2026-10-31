use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FixtureStruct {
    name: String,
    count: u32,
    total: u64,
    ratio: f64,
    on: bool,
    #[schemars(extend("contentEncoding" = "base64"))]
    bytes: String,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FixtureOptional {
    note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hint: Option<u32>,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
enum FixtureUnit {
    #[schemars(title = "Light")]
    Light,
    #[schemars(title = "High Contrast")]
    HighContrast,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(
    tag = "type",
    content = "value",
    rename_all = "camelCase",
    deny_unknown_fields
)]
enum FixtureUnion {
    Empty,
    Plain(FixtureStruct),
    Many(Vec<FixtureUnit>),
    Note(String),
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct FixtureList {
    items: Vec<FixtureStruct>,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct FixtureMap {
    scores: BTreeMap<String, u32>,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FixtureNested {
    shape: FixtureUnion,
    optional: FixtureOptional,
    list: FixtureList,
    map: FixtureMap,
    children: Vec<Self>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fixture {
    #[serde(rename = "type")]
    pub ty: String,
    pub value: Value,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fixtures {
    pub samples: Vec<Fixture>,
    pub rejects: Vec<Fixture>,
    pub said: Vec<Value>,
}

pub fn fixtures() -> Fixtures {
    serde_json::from_str(include_str!("../fixtures/wire.json")).expect("fixtures/wire.json reads")
}

#[cfg(test)]
pub fn round_trip(ty: &str, value: &Value) -> serde_json::Result<Value> {
    fn again<T: Serialize + serde::de::DeserializeOwned>(
        value: &Value,
    ) -> serde_json::Result<Value> {
        serde_json::to_value(T::deserialize(value)?)
    }
    match ty {
        "FixtureStruct" => again::<FixtureStruct>(value),
        "FixtureOptional" => again::<FixtureOptional>(value),
        "FixtureUnit" => again::<FixtureUnit>(value),
        "FixtureUnion" => again::<FixtureUnion>(value),
        "FixtureList" => again::<FixtureList>(value),
        "FixtureMap" => again::<FixtureMap>(value),
        "FixtureNested" => again::<FixtureNested>(value),
        _ => panic!("{ty} isn't a fixture type"),
    }
}
