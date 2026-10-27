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

nonisolated extension ProjectSettings {
    mutating func apply(_ patch: SettingsPatch) {
        mainFile = patch.mainFile ?? mainFile
        engine = patch.engine ?? engine
        stopOnFirstError = patch.stopOnFirstError ?? stopOnFirstError
        shellEscape = patch.shellEscape ?? shellEscape
    }
}

nonisolated extension LogItem {
    var isError: Bool { kind == .error }
}

nonisolated extension CompileResult {
    var failed: Bool { !ok && !stopped }

    var durationText: String {
        Duration.milliseconds(durationMs)
            .formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }
}

nonisolated extension FileIssues {
    var byLine: [Int: IssueLine] { Dictionary(lines.map { ($0.line, $0) }) { $1 } }
}

nonisolated extension SearchHit: Identifiable {
    var id: String { "\(file):\(line):\(before.count)" }
}

nonisolated extension SearchGroup: Identifiable {
    var id: String { file }
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

nonisolated struct SyncSource: Sendable {
    let session: UInt64
    let file: String
    let line, column: Int
    var quietly = false
}

nonisolated extension Snapshot: Identifiable {
    var date: Date { Date(timeIntervalSince1970: Double(time) / 1000) }
    var title: String { name ?? reason ?? String(localized: "Automatic") }
}

func remapPath(_ path: String, from: String, to: String) -> String {
    if path == from { return to }
    if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
    return path
}
