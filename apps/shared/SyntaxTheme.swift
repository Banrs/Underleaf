import Foundation

/// A theme of the core's by its id; an id the core no longer has reads as none.
struct SyntaxTheme: RawRepresentable, Hashable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    init?(rawValue: String) {
        guard Self.listed.contains(where: { $0.id == rawValue }) else { return nil }
        self.rawValue = rawValue
    }

    private init(_ id: String) { rawValue = id }

    static let system = SyntaxTheme("system")
    static let all = listed.map { SyntaxTheme($0.id) }

    var title: String { Self.listed.first { $0.id == rawValue }?.title ?? rawValue }

    private nonisolated struct Listed: Decodable { let id, title: String }

    private static let listed: [Listed] = Syntax.call("themes", [:]) ?? []
}
