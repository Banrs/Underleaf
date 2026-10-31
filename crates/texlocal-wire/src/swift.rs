use std::collections::BTreeSet;
use std::fmt::Write;

use crate::fixtures::{Fixture, Fixtures};
use crate::ir::{Def, Field, Ir, PAYLOAD, Request, Shape, Ty};

const PREAMBLE: &str = r#"import Foundation
import Observation

nonisolated protocol WireRequest: Encodable, Sendable {
    associatedtype Reply: Decodable & Sendable
    static var command: String { get }
}

nonisolated struct Done: Decodable, Hashable, Sendable {
    init() {}

    init(from decoder: any Decoder) throws {
        guard try decoder.singleValueContainer().decodeNil() else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not null"))
        }
    }
}

nonisolated struct WireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

nonisolated extension Decoder {
    func strict<Key: CodingKey & CaseIterable>(_: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let known = Set(Key.allCases.map(\.stringValue))
        if let unknown = try container(keyedBy: WireKey.self).allKeys.first(where: { !known.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [unknown], debugDescription: "Unknown key"))
        }
        return try container(keyedBy: Key.self)
    }
}
"#;

pub fn file(ir: &Ir) -> String {
    let mut out = PREAMBLE.to_owned();
    let mut groups: Vec<&str> = ir.requests.iter().map(|r| r.group.as_str()).collect();
    groups.dedup();
    for group in groups {
        writeln!(
            out,
            "\nnonisolated protocol {group}Request: WireRequest {{}}"
        )
        .unwrap();
    }
    let generic = ir.holding_payload();
    out += &types(ir, &generic);
    for sections in &ir.stores {
        store(&mut out, sections, ir, &generic);
    }
    out
}

pub fn fixtures(ir: &Ir, fixtures: &Fixtures) -> String {
    let listed = |name: &str, list: &[Fixture]| {
        let rows: Vec<String> = list
            .iter()
            .map(|fixture| format!("    ({}.self, #\"{}\"#),\n", fixture.ty, fixture.value))
            .collect();
        format!(
            "\nnonisolated let {name}: [(any (Codable & Hashable & Sendable).Type, String)] = [\n{}]\n",
            rows.concat()
        )
    };
    let said: String = (fixtures.said.iter())
        .map(|said| format!("    #\"{said}\"#,\n"))
        .collect();
    format!(
        "import Foundation\n@testable import TeXLocal\n{}{}{}\nnonisolated let wireSaid = [\n{}]\n",
        types(ir, &ir.holding_payload()),
        listed("wireSamples", &fixtures.samples),
        listed("wireRejects", &fixtures.rejects),
        said,
    )
}

fn types(ir: &Ir, generic: &BTreeSet<&str>) -> String {
    let mut out = String::new();
    for (name, def) in &ir.defs {
        let request = ir.requests.iter().find(|r| r.name == *name);
        out.push('\n');
        match &def.shape {
            Shape::Struct(fields) => structure(&mut out, name, def, fields, request, generic),
            Shape::Units(units) => enumeration(&mut out, name, def, units),
            Shape::Union(cases) => union(&mut out, name, def, cases, generic),
        }
    }
    out
}

fn swift(ty: &Ty, generic: &BTreeSet<&str>) -> String {
    match ty {
        Ty::Bool => "Bool".into(),
        Ty::Int => "Int".into(),
        Ty::UInt64 => "UInt64".into(),
        Ty::Double => "Double".into(),
        Ty::String => "String".into(),
        Ty::Data => "Data".into(),
        Ty::Done => "Done".into(),
        Ty::List(ty) => format!("[{}]", swift(ty, generic)),
        Ty::Map(ty) => format!("[String: {}]", swift(ty, generic)),
        Ty::Optional(ty) => format!("{}?", swift(ty, generic)),
        Ty::Named(name) if generic.contains(name.as_str()) => format!("{name}<{PAYLOAD}>"),
        Ty::Named(name) => name.clone(),
    }
}

fn ident(name: &str) -> String {
    const KEYWORDS: &[&str] = &[
        "as",
        "associatedtype",
        "break",
        "case",
        "catch",
        "class",
        "continue",
        "default",
        "defer",
        "deinit",
        "do",
        "else",
        "enum",
        "extension",
        "fallthrough",
        "false",
        "fileprivate",
        "for",
        "func",
        "guard",
        "if",
        "import",
        "in",
        "init",
        "inout",
        "internal",
        "is",
        "let",
        "nil",
        "open",
        "operator",
        "private",
        "protocol",
        "public",
        "repeat",
        "return",
        "self",
        "static",
        "struct",
        "subscript",
        "super",
        "switch",
        "throw",
        "throws",
        "true",
        "try",
        "typealias",
        "var",
        "where",
        "while",
    ];
    if KEYWORDS.contains(&name) {
        format!("`{name}`")
    } else {
        name.into()
    }
}

fn conformances(def: &Def) -> &'static str {
    match (def.decoded, def.encoded) {
        (true, true) => "Codable, Hashable, Sendable",
        (true, false) => "Decodable, Hashable, Sendable",
        _ => "Encodable, Hashable, Sendable",
    }
}

fn declared(name: &str, def: &Def, generic: &BTreeSet<&str>) -> String {
    if generic.contains(name) {
        format!("{name}<{PAYLOAD}: Decodable & Sendable>: Decodable, Sendable")
    } else {
        format!("{name}: {}", conformances(def))
    }
}

fn keys<'a>(out: &mut String, names: impl IntoIterator<Item = &'a str>) {
    let names: Vec<String> = names.into_iter().map(ident).collect();
    let names = names.join(", ");
    writeln!(
        out,
        "\n    enum CodingKeys: String, CodingKey, CaseIterable {{ case {names} }}"
    )
    .unwrap();
}

fn structure(
    out: &mut String,
    name: &str,
    def: &Def,
    fields: &[Field],
    request: Option<&Request>,
    generic: &BTreeSet<&str>,
) {
    match request {
        Some(request) => {
            writeln!(
                out,
                "nonisolated struct {name}: {}Request {{",
                request.group
            )
            .unwrap();
            let reply = swift(&request.reply, generic);
            writeln!(out, "    typealias Reply = {reply}").unwrap();
            writeln!(out, "    static let command = \"{name}\"").unwrap();
            if !fields.is_empty() {
                out.push('\n');
            }
        }
        None => {
            let declared = declared(name, def, generic);
            writeln!(out, "nonisolated struct {declared} {{").unwrap();
        }
    }
    for field in fields {
        let ty = swift(&field.ty, generic);
        writeln!(out, "    var {}: {ty}", ident(&field.name)).unwrap();
    }
    if !def.decoded {
        out.push_str("}\n");
        return;
    }
    assert!(!fields.is_empty(), "{name} has no fields to read");
    keys(out, fields.iter().map(|field| field.name.as_str()));
    out.push_str("}\n");
    writeln!(out, "\nnonisolated extension {name} {{").unwrap();
    out.push_str("    init(from decoder: any Decoder) throws {\n");
    out.push_str("        let wire = try decoder.strict(CodingKeys.self)\n");
    for field in fields {
        let (decode, ty) = match &field.ty {
            Ty::Optional(ty) if !field.required => ("decodeIfPresent", swift(ty, generic)),
            ty => ("decode", swift(ty, generic)),
        };
        let field = &field.name;
        writeln!(
            out,
            "        {} = try wire.{decode}({ty}.self, forKey: .{field})",
            ident(field)
        )
        .unwrap();
    }
    out.push_str("    }\n");
    if def.encoded {
        out.push_str("\n    func encode(to encoder: any Encoder) throws {\n");
        out.push_str("        var wire = encoder.container(keyedBy: CodingKeys.self)\n");
        for field in fields {
            let encode = if field.required {
                "encode"
            } else {
                "encodeIfPresent"
            };
            let field = &field.name;
            writeln!(
                out,
                "        try wire.{encode}({}, forKey: .{field})",
                ident(field)
            )
            .unwrap();
        }
        out.push_str("    }\n");
    }
    out.push_str("}\n");
}

fn store(out: &mut String, sections: &str, ir: &Ir, generic: &BTreeSet<&str>) {
    let Shape::Union(cases) = &ir.defs[sections].shape else {
        unreachable!("a store's sections are checked")
    };
    let name = sections.trim_end_matches("Section");
    writeln!(out, "\n@Observable\nfinal class {name}Store {{").unwrap();
    for (case, ty) in cases {
        let ty = ty.as_ref().expect("a store's sections are checked");
        let (ty, initial) = match ty {
            Ty::List(_) => (swift(ty, generic), " = []"),
            Ty::Map(_) => (swift(ty, generic), " = [:]"),
            Ty::Optional(_) => (swift(ty, generic), ""),
            _ => (format!("{}?", swift(ty, generic)), ""),
        };
        writeln!(out, "    private(set) var {}: {ty}{initial}", ident(case)).unwrap();
    }
    writeln!(out, "\n    func apply(_ section: {sections}) {{").unwrap();
    out.push_str("        switch section {\n");
    for (case, _) in cases {
        writeln!(out, "        case .{case}(let value): self.{case} = value").unwrap();
    }
    out.push_str("        }\n    }\n}\n");
}

fn enumeration(out: &mut String, name: &str, def: &Def, units: &[(String, Option<String>)]) {
    let codable = conformances(def).replace(", Hashable", ", CaseIterable, Hashable");
    writeln!(out, "nonisolated enum {name}: String, {codable} {{").unwrap();
    let cases: Vec<String> = units.iter().map(|(unit, _)| ident(unit)).collect();
    writeln!(out, "    case {}", cases.join(", ")).unwrap();
    if units.iter().all(|(_, title)| title.is_some()) {
        out.push_str("\n    var title: String {\n        switch self {\n");
        for (unit, title) in units {
            let title = title.as_deref().unwrap_or_default();
            writeln!(out, "        case .{unit}: \"{title}\"").unwrap();
        }
        out.push_str("        }\n    }\n");
    }
    out.push_str("}\n");
}

fn union(
    out: &mut String,
    name: &str,
    def: &Def,
    cases: &[(String, Option<Ty>)],
    generic: &BTreeSet<&str>,
) {
    let declared = declared(name, def, generic);
    writeln!(out, "nonisolated enum {declared} {{").unwrap();
    for (case, value) in cases {
        let value = value
            .as_ref()
            .map(|ty| format!("({})", swift(ty, generic)))
            .unwrap_or_default();
        writeln!(out, "    case {}{value}", ident(case)).unwrap();
    }
    keys(out, ["type", "value"]);
    out.push_str("}\n");
    writeln!(out, "\nnonisolated extension {name} {{").unwrap();
    if def.decoded {
        out.push_str("    init(from decoder: any Decoder) throws {\n");
        out.push_str("        let wire = try decoder.strict(CodingKeys.self)\n");
        out.push_str("        switch try wire.decode(String.self, forKey: .type) {\n");
        for (case, value) in cases {
            match value {
                Some(ty) => writeln!(
                    out,
                    "        case \"{case}\": self = .{case}(try wire.decode({}.self, forKey: .value))",
                    swift(ty, generic)
                ),
                None => writeln!(out, "        case \"{case}\": self = .{case}"),
            }
            .unwrap();
        }
        out.push_str(concat!(
            "        case let type: throw DecodingError.dataCorruptedError(",
            "forKey: .type, in: wire, debugDescription: \"No case \\(type)\")\n",
        ));
        out.push_str("        }\n    }\n");
    }
    if def.encoded {
        if def.decoded {
            out.push('\n');
        }
        out.push_str("    func encode(to encoder: any Encoder) throws {\n");
        out.push_str("        var wire = encoder.container(keyedBy: CodingKeys.self)\n");
        out.push_str("        switch self {\n");
        for (case, value) in cases {
            match value {
                Some(_) => writeln!(
                    out,
                    "        case .{case}(let value):\n            try wire.encode(\"{case}\", forKey: .type)\n            try wire.encode(value, forKey: .value)"
                ),
                None => writeln!(out, "        case .{case}: try wire.encode(\"{case}\", forKey: .type)"),
            }
            .unwrap();
        }
        out.push_str("        }\n    }\n");
    }
    out.push_str("}\n");
}
