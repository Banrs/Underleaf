import Foundation

struct EditSync {
    var mirroring = false
    private var changing: NSRange?
    private var mirrors: [TextEdit] = []

    mutating func willChange(_ ranges: [NSRange], to texts: [String]?) {
        changing = ranges.count == 1 && texts != nil ? ranges[0] : nil
    }

    mutating func edited(_ range: NSRange, delta: Int, in text: NSString, of document: SourceDocument) -> NSRange {
        let old = NSRange(location: range.location, length: range.length - delta)
        mirrors = document.edit(old, with: text.substring(with: range), changing: changing, mirroring: mirroring)
        changing = nil
        return old
    }

    mutating func mirror(composing: Bool) -> [TextEdit] {
        guard !mirroring, !composing else { return [] }
        defer { mirrors = [] }
        return mirrors
    }
}
