use std::panic::catch_unwind;

use schemars::JsonSchema;
use serde_json::Value;

use crate::fixtures::{fixtures, round_trip};
use crate::{digest, read, stale};

#[test]
fn the_generated_files_are_current() {
    let stale: Vec<&str> = stale().into_iter().map(|(path, _)| path).collect();
    assert!(
        stale.is_empty(),
        "{stale:?} stale: run cargo run -p texlocal-wire -- --write"
    );
}

#[test]
fn the_fixtures_round_trip_and_their_rejects_are_refused() {
    let fixtures = fixtures();
    for sample in &fixtures.samples {
        let sent = round_trip(&sample.ty, &sample.value).unwrap();
        assert_eq!(sent, sample.value, "{}", sample.ty);
    }
    for reject in &fixtures.rejects {
        let read = round_trip(&reject.ty, &reject.value);
        assert!(read.is_err(), "{} {}", reject.ty, reject.value);
    }
}

#[test]
#[expect(dead_code)]
fn the_digest_changes_when_a_type_does() {
    mod before {
        #[derive(schemars::JsonSchema)]
        #[serde(deny_unknown_fields)]
        pub struct Same {
            pub count: u32,
        }
    }
    mod retyped {
        #[derive(schemars::JsonSchema)]
        #[serde(deny_unknown_fields)]
        pub struct Same {
            pub count: u64,
        }
    }
    mod renamed {
        #[derive(schemars::JsonSchema)]
        #[serde(deny_unknown_fields)]
        pub struct Same {
            pub total: u32,
        }
    }
    let before = digest(&read::<before::Same>());
    assert_eq!(digest(&read::<before::Same>()), before);
    assert_ne!(digest(&read::<retyped::Same>()), before);
    assert_ne!(digest(&read::<renamed::Same>()), before);
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
        (refused::<Text>(), "SwiftUI"),
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
