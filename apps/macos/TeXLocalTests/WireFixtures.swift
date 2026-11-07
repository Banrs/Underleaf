import Foundation
@testable import TeXLocal

nonisolated struct FixtureList: Codable, Hashable, Sendable {
    var items: [FixtureStruct]
}

nonisolated struct FixtureMap: Codable, Hashable, Sendable {
    var scores: [String: Int]
}

nonisolated struct FixtureNested: Codable, Hashable, Sendable {
    var shape: FixtureUnion
    var optional: FixtureOptional
    var list: FixtureList
    var map: FixtureMap
    var children: [FixtureNested]
}

nonisolated struct FixtureOptional: Codable, Hashable, Sendable {
    var note: String?
    var hint: Int?
}

nonisolated struct FixtureStruct: Codable, Hashable, Sendable {
    var name: String
    var count: Int
    var total: UInt64
    var ratio: Double
    var on: Bool
    var bytes: Data
}

nonisolated enum FixtureUnion: Codable, Hashable, Sendable {
    case empty
    case plain(FixtureStruct)
    case many([FixtureUnit])
    case note(String)

    enum CodingKeys: String, CodingKey { case type, value }
}

nonisolated extension FixtureUnion {
    init(from decoder: any Decoder) throws {
        let wire = try decoder.container(keyedBy: CodingKeys.self)
        switch try wire.decode(String.self, forKey: .type) {
        case "empty": self = .empty
        case "plain": self = .plain(try wire.decode(FixtureStruct.self, forKey: .value))
        case "many": self = .many(try wire.decode([FixtureUnit].self, forKey: .value))
        case "note": self = .note(try wire.decode(String.self, forKey: .value))
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
        case .note(let value):
            try wire.encode("note", forKey: .type)
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
    (FixtureUnion.self, #"{"type":"note","value":"π"}"#),
    (FixtureUnion.self, #"{"type":"plain","value":{"name":"π","count":3,"total":18446744073709551615,"ratio":0.5,"on":true,"bytes":"aGk="}}"#),
    (FixtureList.self, #"{"items":[]}"#),
    (FixtureMap.self, #"{"scores":{"a":1}}"#),
    (FixtureNested.self, #"{"shape":{"type":"many","value":["highContrast"]},"optional":{"note":null},"list":{"items":[]},"map":{"scores":{"a":1}},"children":[]}"#),
]

nonisolated let wireRejects: [(any (Codable & Hashable & Sendable).Type, String)] = [
    (FixtureStruct.self, #"{"name":"a"}"#),
    (FixtureUnit.self, #""dark""#),
    (FixtureUnion.self, #"{"type":"round"}"#),
    (FixtureMap.self, #"{"scores":{"a":"1"}}"#),
]

nonisolated let wireSaid = [
    #"{"type":"reply","value":{"id":7,"answer":{"type":"ok","value":"main.tex"}}}"#,
    #"{"type":"reply","value":{"id":8,"answer":{"type":"error","value":{"kind":"notFound","message":{"id":"no_such_session","args":{},"text":"No such session"}}}}}"#,
    #"{"type":"event","value":{"session":1,"event":{"type":"liveAlert"}}}"#,
    #"{"type":"event","value":{"session":1,"event":{"type":"section","value":{"type":"lifecycle","value":{"type":"stopped","value":{"unsaved":["main.tex"]}}}}}}"#,
    #"{"type":"library","value":{"type":"projects","value":[]}}"#,
    #"{"type":"library","value":{"type":"tex","value":{"available":true,"latexmkVersion":"4.86","texDir":null,"found":"/Library/TeX/texbin","texpresso":null,"texpressoDir":null}}}"#,
    #"{"type":"log","value":{"level":"fault","text":"thread 'texlocal-session-1' panicked at src/session/build.rs:9:5:\nboom"}}"#,
]
