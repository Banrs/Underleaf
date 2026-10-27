#[path = "wire/ir.rs"]
mod ir;
#[path = "wire/swift.rs"]
mod swift;

use std::collections::BTreeMap;
use std::fmt::Debug;
use std::panic::catch_unwind;
use std::path::Path;

use ir::{Ir, Way};
use schemars::JsonSchema;
use schemars::generate::SchemaSettings;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

fn current(rel: &str, text: &str) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel);
    if std::env::var_os("BLESS").is_some() {
        std::fs::write(&path, text).unwrap();
    } else {
        let written = std::fs::read_to_string(&path).unwrap_or_default();
        assert!(
            written == text,
            "{rel} is stale: run BLESS=1 cargo test -p texlocal-core --test wire"
        );
    }
}

fn read<T: JsonSchema>(ir: &mut Ir) {
    for (way, settings) in [
        (Way::Out, SchemaSettings::draft2020_12().for_serialize()),
        (Way::In, SchemaSettings::draft2020_12().for_deserialize()),
    ] {
        let mut generator = settings.into_generator();
        generator.subschema_for::<T>();
        ir.add(generator.definitions(), way);
    }
}

#[test]
fn wire_swift_is_generated_from_the_protocol() {
    let protocol = texlocal_core::protocol::protocol();
    let mut ir = Ir::default();
    ir.add(&protocol.inbound, Way::In);
    ir.add(&protocol.outbound, Way::Out);
    for request in &protocol.requests {
        let (call, reply) = (request.request.as_value(), request.reply.as_value());
        ir.request(request.name, request.group, call, reply);
    }
    ir.check();
    current("apps/macos/TeXLocal/Wire.swift", &swift::file(&ir));
}

#[derive(Debug, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FixtureStruct {
    name: String,
    count: u32,
    total: u64,
    ratio: f64,
    on: bool,
}

#[derive(Debug, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FixtureOptional {
    note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hint: Option<u32>,
}

#[derive(Debug, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
enum FixtureUnit {
    #[schemars(title = "Light")]
    Light,
    #[schemars(title = "High Contrast")]
    HighContrast,
}

#[derive(Debug, PartialEq, Serialize, Deserialize, JsonSchema)]
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
}

#[derive(Debug, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct FixtureList {
    items: Vec<FixtureStruct>,
}

#[derive(Debug, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct FixtureMap {
    scores: BTreeMap<String, u32>,
}

#[derive(Debug, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct FixtureNested {
    shape: FixtureUnion,
    optional: FixtureOptional,
    list: FixtureList,
    map: FixtureMap,
    children: Vec<Self>,
}

fn sample<T: Serialize + DeserializeOwned + PartialEq + Debug>(value: &T) -> String {
    let json = serde_json::to_string(value).unwrap();
    assert_eq!(&serde_json::from_str::<T>(&json).unwrap(), value);
    json
}

fn reject<T: DeserializeOwned>(json: Value) -> String {
    assert!(serde_json::from_value::<T>(json.clone()).is_err(), "{json}");
    json.to_string()
}

#[test]
fn the_fixtures_round_trip_and_their_swift_is_current() {
    let plain = FixtureStruct {
        name: "π".into(),
        count: 3,
        total: u64::MAX,
        ratio: 0.5,
        on: true,
    };
    let note = FixtureOptional {
        note: Some("n".into()),
        hint: Some(2),
    };
    let nested = FixtureNested {
        shape: FixtureUnion::Many(vec![FixtureUnit::HighContrast]),
        optional: FixtureOptional {
            note: None,
            hint: None,
        },
        list: FixtureList { items: vec![] },
        map: FixtureMap {
            scores: BTreeMap::from([("a".into(), 1)]),
        },
        children: vec![],
    };
    let samples = [
        ("FixtureStruct", sample(&plain)),
        ("FixtureOptional", sample(&note)),
        ("FixtureUnit", sample(&FixtureUnit::Light)),
        ("FixtureUnion", sample(&FixtureUnion::Empty)),
        ("FixtureUnion", sample(&FixtureUnion::Plain(plain))),
        ("FixtureList", sample(&FixtureList { items: vec![] })),
        ("FixtureMap", sample(&nested.map)),
        ("FixtureNested", sample(&nested)),
    ];
    let full = json!({ "name": "a", "count": 1, "total": 1, "ratio": 1.0, "on": false });
    let mut extra = full.clone();
    extra["more"] = json!(1);
    let rejects = [
        ("FixtureStruct", reject::<FixtureStruct>(extra)),
        (
            "FixtureStruct",
            reject::<FixtureStruct>(json!({ "name": "a" })),
        ),
        (
            "FixtureOptional",
            reject::<FixtureOptional>(json!({ "note": null, "more": 1 })),
        ),
        ("FixtureUnit", reject::<FixtureUnit>(json!("dark"))),
        (
            "FixtureUnion",
            reject::<FixtureUnion>(json!({ "type": "round" })),
        ),
        (
            "FixtureUnion",
            reject::<FixtureUnion>(json!({ "type": "plain", "value": full, "more": 1 })),
        ),
        (
            "FixtureMap",
            reject::<FixtureMap>(json!({ "scores": { "a": "1" } })),
        ),
    ];
    let mut ir = Ir::default();
    read::<FixtureNested>(&mut ir);
    ir.check();
    let listed = |name: &str, list: &[(&str, String)]| {
        let rows: Vec<String> = list
            .iter()
            .map(|(ty, json)| format!("    ({ty}.self, #\"{json}\"#),\n"))
            .collect();
        format!(
            "\nnonisolated let {name}: [(any (Codable & Hashable & Sendable).Type, String)] = [\n{}]\n",
            rows.concat()
        )
    };
    let text = format!(
        "import Foundation\n@testable import TeXLocal\n{}{}{}",
        swift::types(&ir),
        listed("wireSamples", &samples),
        listed("wireRejects", &rejects),
    );
    current("apps/macos/TeXLocalTests/WireFixtures.swift", &text);
}

fn refused<T: JsonSchema>() -> String {
    let panic = catch_unwind(|| read::<T>(&mut Ir::default())).expect_err("the shape was refused");
    panic.downcast_ref::<String>().cloned().unwrap_or_default()
}

#[test]
#[expect(dead_code)]
fn the_generator_refuses_what_swift_would_read_differently() {
    #[derive(JsonSchema)]
    struct Loose {
        value: Value,
    }
    #[derive(JsonSchema)]
    struct Pair {
        pair: (u32, u32),
    }
    #[derive(JsonSchema)]
    struct Typed {
        r#type: String,
    }
    #[derive(JsonSchema)]
    struct Snake {
        snake_case: u32,
    }
    #[derive(JsonSchema)]
    #[serde(tag = "type")]
    enum Internal {
        A { a: u32 },
    }
    #[derive(JsonSchema)]
    #[serde(untagged)]
    enum Untagged {
        A(u32),
        B(String),
    }
    #[derive(JsonSchema)]
    struct Text {
        text: String,
    }
    mod one {
        #[derive(schemars::JsonSchema)]
        pub struct Same {
            pub one: u32,
        }
    }
    mod two {
        #[derive(schemars::JsonSchema)]
        pub struct Same {
            pub two: u32,
        }
    }
    #[derive(JsonSchema)]
    struct Both {
        one: one::Same,
        two: two::Same,
    }
    #[derive(JsonSchema)]
    struct Open {
        open: u32,
    }
    #[derive(JsonSchema)]
    #[serde(deny_unknown_fields)]
    struct Defaulted {
        #[serde(default)]
        count: u32,
    }
    #[derive(JsonSchema)]
    struct Skipped {
        #[serde(skip_serializing_if = "Vec::is_empty")]
        items: Vec<u32>,
    }
    let cases = [
        (refused::<Loose>(), "untyped"),
        (refused::<Pair>(), "isn't written for"),
        (refused::<Typed>(), "named type"),
        (refused::<Snake>(), "camelCase"),
        (refused::<Internal>(), "adjacently tagged"),
        (refused::<Untagged>(), "untagged"),
        (refused::<Text>(), "SwiftUI"),
        (refused::<Both>(), "two types are named Same"),
        (refused::<Open>(), "deny_unknown_fields"),
        (refused::<Defaulted>(), "left out"),
        (refused::<Skipped>(), "left out"),
    ];
    for (panic, expected) in cases {
        assert!(
            panic.contains(expected),
            "{panic:?} doesn't say {expected:?}"
        );
    }
}
