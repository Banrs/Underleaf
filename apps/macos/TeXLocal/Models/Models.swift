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
        case _ where isDirectory: "folder.fill"
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
    func isWithin(_ folder: String) -> Bool { self == folder || hasPrefix(folder + "/") }
}

nonisolated extension NSRange {
    static func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }
}

nonisolated extension LogItem {
    var isError: Bool { kind == .error }

    /// Read from its words as the core sets them: bad boxes are TeX's "Overfull \…" and "Underfull \…" lines, and undefined
    /// references are TeX's warnings about them and the core's own "No label …" and "No citation …".
    var issueKind: IssueKind {
        let text = message.text
        if isError { return .error }
        if text.hasPrefix("Overfull \\") || text.hasPrefix("Underfull \\") { return .badBox }
        if text.wholeMatch(of: Self.undefinedReference) != nil || text.hasPrefix("No label ") || text.hasPrefix("No citation ")
            || text.hasPrefix("There were undefined references") || text.hasPrefix("There were undefined citations") {
            return .undefinedReference
        }
        return .warning
    }

    nonisolated(unsafe) private static let undefinedReference = #/(?:Reference|Citation) `.*' on page \S+ undefined.*/#
}

/// The kinds of issue the Issues filter's menu shows or hides.
nonisolated enum IssueKind: CaseIterable, Hashable, Sendable {
    case error, warning, badBox, undefinedReference

    var title: String {
        switch self {
        case .error: String(localized: "Errors")
        case .warning: String(localized: "Warnings")
        case .badBox: String(localized: "Bad Boxes")
        case .undefinedReference: String(localized: "Undefined References")
        }
    }
}

/// The kinds of line the Logs filter's menu shows or hides, each line taking the kind of the entry it belongs to, as the
/// core reads them: an error from its "!" or "file:line:" line to the line after its "l.<line>", a warning from its
/// "Warning:" line to the next line that isn't its continuation, and a bad box to the next blank line. A line after one
/// TeX wrapped at 79 bytes continues it.
nonisolated enum LogKind: CaseIterable, Hashable, Sendable {
    case error, warning, badBox, info

    var title: String {
        switch self {
        case .error: String(localized: "Errors")
        case .warning: String(localized: "Warnings")
        case .badBox: String(localized: "Bad Boxes")
        case .info: String(localized: "Info")
        }
    }

    static func of(_ lines: [Substring]) -> [LogKind] {
        var kinds: [LogKind] = []
        kinds.reserveCapacity(lines.count)
        var entry: LogKind = .info, endsAfterNext = false, wrapped = false
        for line in lines {
            defer { wrapped = line.utf8.count == 79 }
            if wrapped {
                kinds.append(entry)
                continue
            }
            if line.hasPrefix("!") || line.prefixMatch(of: fileLineError) != nil {
                (entry, endsAfterNext) = (.error, false)
            } else if line.hasPrefix("Overfull \\") || line.hasPrefix("Underfull \\") {
                entry = .badBox
            } else if line.contains("Warning:") {
                entry = .warning
            } else if line.isEmpty {
                entry = .info
            } else if entry == .error, endsAfterNext {
                // The rest of TeX's context, after its "l.<line>".
                kinds.append(.error)
                (entry, endsAfterNext) = (.info, false)
                continue
            } else if entry == .error, line.hasPrefix("l."), line.dropFirst(2).first?.isNumber == true {
                endsAfterNext = true
            } else if entry == .warning, !(line.hasPrefix("(") || line.first?.isWhitespace == true) {
                entry = .info
            }
            kinds.append(entry)
        }
        return kinds
    }

    nonisolated(unsafe) private static let fileLineError = #/[^\s:][^:]*:\d+: /#
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
