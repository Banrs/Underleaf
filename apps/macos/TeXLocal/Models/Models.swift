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
    var folder: String { isDirectory ? path : path.parentFolder }

    var symbol: String {
        switch kind {
        case _ where isDirectory: "folder.fill"
        case .tex: "text.document"
        case .bib: "books.vertical"
        case .image: "photo"
        case .pdf: "richtext.page"
        default: "document"
        }
    }
}

extension [TreeNode] {
    var flattened: [TreeNode] { flatMap { [$0] + ($0.children ?? []).flattened } }

    var ordered: [TreeNode] {
        map { node in
            var node = node
            node.children = node.children?.ordered
            return node
        }
        .sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func node(at path: String) -> TreeNode? {
        first { path.isWithin($0.path) }.flatMap { $0.path == path ? $0 : $0.children?.node(at: path) }
    }
}

nonisolated extension String {
    var parentFolder: String { (self as NSString).deletingLastPathComponent }
    var fileName: String { (self as NSString).lastPathComponent }
    func appending(component name: String) -> String { isEmpty ? name : "\(self)/\(name)" }
    func isWithin(_ folder: String) -> Bool { self == folder || hasPrefix(folder + "/") }
}

nonisolated extension NSRange {
    static func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }
}

nonisolated extension Set {
    /// Whether the member is left out. Setting it removes or inserts the member, so a binding to a set of folded or hidden
    /// things can drive whether one of them is expanded or shown.
    subscript(lacks member: Element) -> Bool {
        get { !contains(member) }
        set { if newValue { remove(member) } else { insert(member) } }
    }
}

nonisolated extension LogItem {
    var isError: Bool { kind == .error }

    var issueKind: IssueKind {
        switch topic {
        case _ where isError: .error
        case .badBox: .badBox
        case .undefinedReference: .undefinedReference
        case nil: .warning
        }
    }
}

/// The kinds of issue the Issues filter's menu shows or hides.
nonisolated enum IssueKind: CaseIterable, Hashable, Sendable {
    case error, warning, badBox, undefinedReference

    static let warnings = Set(allCases).subtracting([.error])

    var title: String {
        switch self {
        case .error: String(localized: "Errors")
        case .warning: String(localized: "Warnings")
        case .badBox: String(localized: "Bad Boxes")
        case .undefinedReference: String(localized: "Undefined References")
        }
    }
}

nonisolated extension LogKind {
    var title: String {
        switch self {
        case .error: String(localized: "Errors")
        case .warning: String(localized: "Warnings")
        case .badBox: String(localized: "Bad Boxes")
        case .info: String(localized: "Info")
        }
    }
}

nonisolated extension CompileResult {
    var failed: Bool { !ok && !stopped }

    var durationText: String {
        Duration.milliseconds(durationMs)
            .formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }
}

nonisolated extension BuildState {
    var listed: [LogItem] { issues + (result?.badBoxes ?? []) }
}

extension [IssueLine] {
    var byLine: [Int: IssueLine] { Dictionary(map { ($0.line, $0) }) { $1 } }
}

nonisolated extension SearchHit: Identifiable {
    var id: String { "\(file):\(line):\(column)" }
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
    let session: SessionClient
    let file: String
    let line, column: Int
    var wordOnly = false
}

nonisolated extension Snapshot: Identifiable {
    var date: Date { Date(timeIntervalSince1970: Double(time) / 1000) }
    var title: String { name ?? reason?.title ?? String(localized: "Automatic") }
}

func remapPath(_ path: String, from: String, to: String) -> String {
    path.isWithin(from) ? to + path.dropFirst(from.count) : path
}

nonisolated enum PDFPaper: String, CaseIterable, Identifiable {
    case white, dark, auto

    var id: Self { self }

    func isDark(inDarkAppearance dark: Bool) -> Bool { self == .dark || self == .auto && dark }

    var title: LocalizedStringResource {
        switch self {
        case .white: "White"
        case .dark: "Dark"
        case .auto: "Match Appearance"
        }
    }
}

enum SettingsPane: String { case general, editor, compiling, pdf, livePreview }
