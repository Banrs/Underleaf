import Foundation
@testable import TeXLocal

nonisolated struct FixtureList: Codable, Hashable, Sendable {
    var items: [FixtureStruct]

    enum CodingKeys: String, CodingKey, CaseIterable { case items }
}

nonisolated extension FixtureList {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        items = try wire.decode([FixtureStruct].self, forKey: .items)
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        try wire.encode(items, forKey: .items)
    }
}

nonisolated struct FixtureMap: Codable, Hashable, Sendable {
    var scores: [String: Int]

    enum CodingKeys: String, CodingKey, CaseIterable { case scores }
}

nonisolated extension FixtureMap {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        scores = try wire.decode([String: Int].self, forKey: .scores)
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        try wire.encode(scores, forKey: .scores)
    }
}

nonisolated struct FixtureNested: Codable, Hashable, Sendable {
    var shape: FixtureUnion
    var optional: FixtureOptional
    var list: FixtureList
    var map: FixtureMap
    var children: [FixtureNested]

    enum CodingKeys: String, CodingKey, CaseIterable { case shape, optional, list, map, children }
}

nonisolated extension FixtureNested {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        shape = try wire.decode(FixtureUnion.self, forKey: .shape)
        optional = try wire.decode(FixtureOptional.self, forKey: .optional)
        list = try wire.decode(FixtureList.self, forKey: .list)
        map = try wire.decode(FixtureMap.self, forKey: .map)
        children = try wire.decode([FixtureNested].self, forKey: .children)
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        try wire.encode(shape, forKey: .shape)
        try wire.encode(optional, forKey: .optional)
        try wire.encode(list, forKey: .list)
        try wire.encode(map, forKey: .map)
        try wire.encode(children, forKey: .children)
    }
}

nonisolated struct FixtureOptional: Codable, Hashable, Sendable {
    var note: String?
    var hint: Int?

    enum CodingKeys: String, CodingKey, CaseIterable { case note, hint }
}

nonisolated extension FixtureOptional {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        note = try wire.decode(String?.self, forKey: .note)
        hint = try wire.decodeIfPresent(Int.self, forKey: .hint)
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        try wire.encode(note, forKey: .note)
        try wire.encodeIfPresent(hint, forKey: .hint)
    }
}

nonisolated struct FixtureStruct: Codable, Hashable, Sendable {
    var name: String
    var count: Int
    var total: UInt64
    var ratio: Double
    var on: Bool
    var bytes: Data

    enum CodingKeys: String, CodingKey, CaseIterable { case name, count, total, ratio, on, bytes }
}

nonisolated extension FixtureStruct {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        name = try wire.decode(String.self, forKey: .name)
        count = try wire.decode(Int.self, forKey: .count)
        total = try wire.decode(UInt64.self, forKey: .total)
        ratio = try wire.decode(Double.self, forKey: .ratio)
        on = try wire.decode(Bool.self, forKey: .on)
        bytes = try wire.decode(Data.self, forKey: .bytes)
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        try wire.encode(name, forKey: .name)
        try wire.encode(count, forKey: .count)
        try wire.encode(total, forKey: .total)
        try wire.encode(ratio, forKey: .ratio)
        try wire.encode(on, forKey: .on)
        try wire.encode(bytes, forKey: .bytes)
    }
}

nonisolated enum FixtureUnion: Codable, Hashable, Sendable {
    case empty
    case plain(FixtureStruct)
    case many([FixtureUnit])

    enum CodingKeys: String, CodingKey, CaseIterable { case type, value }
}

nonisolated extension FixtureUnion {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.strict(CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "empty": self = .empty
        case "plain": self = .plain(try wire.decode(FixtureStruct.self, forKey: .value))
        case "many": self = .many(try wire.decode([FixtureUnit].self, forKey: .value))
        case let type: throw DecodingError.dataCorruptedError(forKey: .type, in: wire, debugDescription: "No case \(type)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var wire = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty: try wire.encode("empty", forKey: .type)
        case .plain(let value):
            try wire.encode("plain", forKey: .type)
            try wire.encode(value, forKey: .value)
        case .many(let value):
            try wire.encode("many", forKey: .type)
            try wire.encode(value, forKey: .value)
        }
    }
}

nonisolated enum FixtureUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case light, highContrast

    var title: String {
        switch self {
        case .light: "Light"
        case .highContrast: "High Contrast"
        }
    }
}

nonisolated let wireSamples: [(any (Codable & Hashable & Sendable).Type, String)] = [
    (FixtureStruct.self, #"{"name":"π","count":3,"total":18446744073709551615,"ratio":0.5,"on":true,"bytes":"aGk="}"#),
    (FixtureOptional.self, #"{"note":"n","hint":2}"#),
    (FixtureUnit.self, #""light""#),
    (FixtureUnion.self, #"{"type":"empty"}"#),
    (FixtureUnion.self, #"{"type":"plain","value":{"name":"π","count":3,"total":18446744073709551615,"ratio":0.5,"on":true,"bytes":"aGk="}}"#),
    (FixtureList.self, #"{"items":[]}"#),
    (FixtureMap.self, #"{"scores":{"a":1}}"#),
    (FixtureNested.self, #"{"shape":{"type":"many","value":["highContrast"]},"optional":{"note":null},"list":{"items":[]},"map":{"scores":{"a":1}},"children":[]}"#),
]

nonisolated let wireRejects: [(any (Codable & Hashable & Sendable).Type, String)] = [
    (FixtureStruct.self, #"{"name":"a","count":1,"total":1,"ratio":1.0,"on":false,"bytes":"","more":1}"#),
    (FixtureStruct.self, #"{"name":"a"}"#),
    (FixtureOptional.self, #"{"note":null,"more":1}"#),
    (FixtureUnit.self, #""dark""#),
    (FixtureUnion.self, #"{"type":"round"}"#),
    (FixtureUnion.self, #"{"type":"plain","value":{"name":"a","count":1,"total":1,"ratio":1.0,"on":false,"bytes":""},"more":1}"#),
    (FixtureMap.self, #"{"scores":{"a":"1"}}"#),
]
