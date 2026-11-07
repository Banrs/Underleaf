use std::panic::catch_unwind;

use schemars::JsonSchema;
use schemars::generate::SchemaSettings;
use serde_json::Value;

use crate::ir::{Ir, Way};
use crate::stale;

#[test]
fn the_generated_files_are_current() {
    let stale: Vec<&str> = stale().into_iter().map(|(path, _)| path).collect();
    assert!(
        stale.is_empty(),
        "{stale:?} stale: run cargo run -p texlocal-wire -- --write"
    );
}

fn read<T: JsonSchema>() -> Ir {
    let mut ir = Ir::default();
    for (way, settings) in [
        (Way::Out, SchemaSettings::draft2020_12().for_serialize()),
        (Way::In, SchemaSettings::draft2020_12().for_deserialize()),
    ] {
        let mut generator = settings.into_generator();
        generator.subschema_for::<T>();
        ir.add(generator.definitions(), way);
    }
    ir.check();
    ir
}

fn refused<T: JsonSchema>() -> String {
    let panic = catch_unwind(|| {
        read::<T>();
    })
    .expect_err("the shape was refused");
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
    struct Hex {
        #[schemars(extend("contentEncoding" = "base16"))]
        hex: String,
    }
    #[derive(JsonSchema)]
    struct Skipped {
        #[serde(skip_serializing_if = "Vec::is_empty")]
        items: Vec<u32>,
    }
    #[derive(JsonSchema)]
    struct Payload {
        payload: u32,
    }
    #[derive(JsonSchema)]
    enum Twice {
        #[serde(rename = "a_b")]
        A,
        #[serde(rename = "aB")]
        B,
    }
    let cases = [
        (refused::<Loose>(), "untyped"),
        (refused::<Pair>(), "isn't written for"),
        (refused::<Typed>(), "named type"),
        (refused::<Snake>(), "camelCase"),
        (refused::<Internal>(), "adjacently tagged"),
        (refused::<Untagged>(), "untagged"),
        (refused::<Both>(), "two types are named Same"),
        (refused::<Open>(), "deny_unknown_fields"),
        (refused::<Defaulted>(), "left out"),
        (refused::<Skipped>(), "left out"),
        (refused::<Hex>(), "encoded as \"base16\""),
        (refused::<Payload>(), "Payload is a type's name"),
        (refused::<Twice>(), "a case twice"),
    ];
    for (panic, expected) in cases {
        assert!(
            panic.contains(expected),
            "{panic:?} doesn't say {expected:?}"
        );
    }
}
