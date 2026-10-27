import Foundation

nonisolated extension ProjectInfo: Identifiable {
    var modified: Date { Date(timeIntervalSince1970: Double(mtime) / 1000) }
    var folder: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

nonisolated extension ProjectTemplate: Identifiable {
    var id: Self { self }
}

nonisolated extension TreeNode: Identifiable {
    var id: String { path }
    var isDirectory: Bool { children != nil }

    var symbol: String {
        switch kind {
        case _ where isDirectory: "folder"
        case .tex: "text.document"
        case .bib: "books.vertical"
        case .image: "photo"
        case .pdf: "richtext.page"
        default: "document"
        }
    }
}

nonisolated extension FileKind {
    var isText: Bool { self == .tex || self == .bib || self == .text }
}

extension [TreeNode] {
    var flattened: [TreeNode] { flatMap { [$0] + ($0.children ?? []).flattened } }
}

nonisolated extension String {
    var parentFolder: String { (self as NSString).deletingLastPathComponent }
    var fileName: String { (self as NSString).lastPathComponent }
}

nonisolated extension NSRange {
    static func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }
}

nonisolated struct ProjectSettings: Decodable {
    var mainFile, engine: String
    var shellEscape, stopOnFirstError: Bool
}

nonisolated struct SettingsChange {
    let patch: [String: any Sendable]
    let apply: (inout ProjectSettings) -> Void

    static func mainFile(_ path: String) -> Self { Self(patch: ["mainFile": path]) { $0.mainFile = path } }
    static func engine(_ name: String) -> Self { Self(patch: ["engine": name]) { $0.engine = name } }
    static func shellEscape(_ on: Bool) -> Self { Self(patch: ["shellEscape": on]) { $0.shellEscape = on } }
    static func stopOnFirstError(_ on: Bool) -> Self {
        Self(patch: ["stopOnFirstError": on]) { $0.stopOnFirstError = on }
    }
}

nonisolated struct LogItem: Decodable {
    let type: String
    let file: String?
    let line: Int?
    let message: String
    let explain: String?
    let fix: Fix?

    var isError: Bool { type == "error" }

    nonisolated struct Fix: Decodable, Equatable {
        let id, title, help: String
        let confirm: String?
    }
}

nonisolated struct CompileResult: Decodable {
    let ok, stopped: Bool
    let pdf: String?
    let pdfChanged: Bool
    let durationMs: Int
    let errors, warnings, badBoxes: [LogItem]
    let log: String

    var failed: Bool { !ok && !stopped }

    var durationText: String {
        Duration.milliseconds(durationMs)
            .formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }
}

nonisolated struct SearchHit: Decodable, Identifiable {
    let file: String
    let line, column, length: Int
    let before, match, after: String

    var id: String { "\(file):\(line):\(before.count)" }
}

nonisolated struct SearchGroup: Decodable, Identifiable {
    let file: String
    let hits: [SearchHit]

    var id: String { file }
}

nonisolated struct Usages: Decodable {
    let name: String
    let groups: [SearchGroup]
}

struct Place: Equatable {
    var path: String
    let line: Int
}

struct Trail {
    private(set) var back: [Place] = [], forward: [Place] = []

    mutating func jumped(from place: Place) {
        Self.push(place, on: &back)
        forward.removeAll()
    }

    mutating func step(back: Bool, from at: Place, exists: (Place) -> Bool) -> Place? {
        var (from, other) = back ? (self.back, forward) : (forward, self.back)
        var to: Place?
        while let place = from.popLast() {
            if place != at && exists(place) { to = place; break }
        }
        if to != nil { Self.push(at, on: &other) }
        (self.back, forward) = back ? (from, other) : (other, from)
        return to
    }

    mutating func moved(_ from: String, to: String) {
        for index in back.indices { back[index].path = remapPath(back[index].path, from: from, to: to) }
        for index in forward.indices { forward[index].path = remapPath(forward[index].path, from: from, to: to) }
    }

    private static func push(_ place: Place, on places: inout [Place]) {
        if places.last != place { places.append(place) }
        if places.count > 50 { places.removeFirst() }
    }
}

nonisolated struct QuickHelp: Decodable {
    let title, detail: String
    let place: Definition.Place?
}

nonisolated struct SyncSource: Sendable {
    let id, file: String
    let line, column: Int
    var quietly = false
}

nonisolated struct RenameResult: Decodable {
    let from, to, mainFile: String
    let ui: UIState
}

nonisolated struct Snapshot: Decodable, Identifiable {
    nonisolated struct Change: Decodable {
        nonisolated enum Kind: String, Decodable { case added, deleted, changed }

        let path: String
        let change: Kind
    }

    let id: String
    private let time: Double
    let name, reason: String?
    let changed: [Change]

    var date: Date { Date(timeIntervalSince1970: time / 1000) }
    var title: String { name ?? reason ?? String(localized: "Automatic") }
}

nonisolated struct DiffLine: Decodable { let same, removed, added: String?; let skipped: Int? }

func remapPath(_ path: String, from: String, to: String) -> String {
    if path == from { return to }
    if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
    return path
}
