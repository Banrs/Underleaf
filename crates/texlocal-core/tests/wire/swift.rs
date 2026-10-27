use std::fmt::Write;

use super::ir::{Def, Field, Ir, Request, Shape, Ty};

const PREAMBLE: &str = r#"import Foundation

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
    out + &types(ir)
}

pub fn types(ir: &Ir) -> String {
    let mut out = String::new();
    for (name, def) in &ir.defs {
        let request = ir.requests.iter().find(|r| r.name == *name);
        out.push('\n');
        match &def.shape {
            Shape::Struct(fields) => structure(&mut out, name, def, fields, request),
            Shape::Units(units) => enumeration(&mut out, name, def, units),
            Shape::Union(cases) => union(&mut out, name, def, cases),
        }
    }
    out
}

fn swift(ty: &Ty) -> String {
    match ty {
        Ty::Bool => "Bool".into(),
        Ty::Int => "Int".into(),
        Ty::UInt64 => "UInt64".into(),
        Ty::Double => "Double".into(),
        Ty::String => "String".into(),
        Ty::Done => "Done".into(),
        Ty::List(ty) => format!("[{}]", swift(ty)),
        Ty::Map(ty) => format!("[String: {}]", swift(ty)),
        Ty::Optional(ty) => format!("{}?", swift(ty)),
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

fn keys(out: &mut String, names: impl Iterator<Item = String>) {
    let names: Vec<String> = names.map(|name| ident(&name)).collect();
    let names = names.join(", ");
    writeln!(
        out,
        "\n    enum CodingKeys: String, CodingKey, CaseIterable {{ case {names} }}"
    )
    .unwrap();
}

fn structure(out: &mut String, name: &str, def: &Def, fields: &[Field], request: Option<&Request>) {
    let optional = |field: &Field| !field.required && !matches!(field.ty, Ty::Optional(_));
    match request {
        Some(request) => {
            writeln!(
                out,
                "nonisolated struct {name}: {}Request {{",
                request.group
            )
            .unwrap();
            writeln!(out, "    typealias Reply = {}", swift(&request.reply)).unwrap();
            writeln!(out, "    static let command = \"{name}\"").unwrap();
            if !fields.is_empty() {
                out.push('\n');
            }
        }
        None => writeln!(out, "nonisolated struct {name}: {} {{", conformances(def)).unwrap(),
    }
    for field in fields {
        let mark = if optional(field) { "?" } else { "" };
        writeln!(
            out,
            "    var {}: {}{mark}",
            ident(&field.name),
            swift(&field.ty)
        )
        .unwrap();
    }
    if !def.decoded {
        out.push_str("}\n");
        return;
    }
    assert!(!fields.is_empty(), "{name} has no fields to read");
    keys(out, fields.iter().map(|field| field.name.clone()));
    out.push_str("}\n");
    writeln!(out, "\nnonisolated extension {name} {{").unwrap();
    out.push_str("    init(from decoder: any Decoder) throws {\n");
    out.push_str("        let wire = try decoder.strict(CodingKeys.self)\n");
    for field in fields {
        let (decode, ty) = match (optional(field), &field.ty) {
            (true, ty) => ("decodeIfPresent", swift(ty)),
            (false, Ty::Optional(ty)) if !field.required => ("decodeIfPresent", swift(ty)),
            (false, ty) => ("decode", swift(ty)),
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

fn union(out: &mut String, name: &str, def: &Def, cases: &[(String, Option<Ty>)]) {
    writeln!(out, "nonisolated enum {name}: {} {{", conformances(def)).unwrap();
    for (case, value) in cases {
        let value = value
            .as_ref()
            .map(|ty| format!("({})", swift(ty)))
            .unwrap_or_default();
        writeln!(out, "    case {}{value}", ident(case)).unwrap();
    }
    keys(out, ["type", "value"].map(String::from).into_iter());
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
                    swift(ty)
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
