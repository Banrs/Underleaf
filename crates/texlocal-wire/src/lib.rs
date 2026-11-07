mod ir;
mod swift;

use std::fs;
use std::path::Path;

use ir::{Ir, Way};
use serde_json::Value;

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
    for kinds in &protocol.packed {
        ir.pack(kinds.as_value());
    }
    ir.check();
    ir
}

pub fn stale() -> Vec<(&'static str, String)> {
    let ir = protocol();
    let fixtures = include_str!("../fixtures/wire.json");
    let fixtures: Value = serde_json::from_str(fixtures).expect("fixtures/wire.json reads");
    let said = swift::said(&fixtures["said"]);
    let files = [
        ("apps/macos/TeXLocal/Models/Wire.swift", swift::file(&ir)),
        ("apps/macos/TeXLocalTests/WireFixtures.swift", said),
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
