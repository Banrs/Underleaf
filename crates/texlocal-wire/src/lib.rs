mod fixtures;
mod ir;
mod swift;

use std::fs;
use std::path::Path;

use ir::{Ir, Way};
use schemars::JsonSchema;
use schemars::generate::SchemaSettings;
use sha2::Digest;

pub const ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");

fn protocol() -> Ir {
    let protocol = texlocal_core::protocol::protocol();
    let mut ir = Ir::default();
    ir.add(&protocol.inbound, Way::In);
    ir.add(&protocol.outbound, Way::Out);
    for request in &protocol.requests {
        let (call, reply) = (request.request.as_value(), request.reply.as_value());
        ir.request(request.name, request.group, call, reply);
    }
    for store in &protocol.stores {
        ir.store(store.as_value());
    }
    ir.check();
    ir
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

fn digest(ir: &Ir) -> String {
    let ir = serde_json::to_vec(ir).expect("the IR serialises");
    let digest = sha2::Sha256::digest(ir);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn stale() -> Vec<(&'static str, String)> {
    let ir = protocol();
    let digest = digest(&ir);
    let fixtures = swift::fixtures(&read::<fixtures::FixtureNested>(), &fixtures::fixtures());
    let files = [
        ("apps/macos/TeXLocal/Wire.swift", swift::file(&ir, &digest)),
        ("apps/macos/TeXLocalTests/WireFixtures.swift", fixtures),
        (
            "crates/texlocal-core/src/protocol/digest.rs",
            format!("pub const DIGEST: &str = \"{digest}\";\n"),
        ),
    ];
    let current = |path: &str, text: &str| {
        fs::read_to_string(Path::new(ROOT).join(path)).is_ok_and(|written| written == text)
    };
    files
        .into_iter()
        .filter(|(path, text)| !current(path, text))
        .collect()
}

#[cfg(test)]
mod tests;
