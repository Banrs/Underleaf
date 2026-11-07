import Foundation

struct EditSync {
    var mirroring = false
    private var changing: NSRange?
    private var batched: [TextEdit] = []
    private var mirrors: [TextEdit] = []

    mutating func willChange(_ ranges: [NSRange], to texts: [String]?) {
        changing = ranges.count == 1 && texts != nil ? ranges[0] : nil
    }

    /// An edit made in a TextKit pass of several, which the core takes as if it had its own.
    mutating func batch(_ edit: TextEdit) { batched.append(edit) }

    /// Tells the core of the edits TextKit processed, which it returns with the ranges they replaced.
    mutating func edited(_ range: NSRange, delta: Int, in text: NSString, of document: SourceDocument) -> [TextEdit] {
        let edits = batched.isEmpty
            ? [TextEdit(NSRange(location: range.location, length: range.length - delta), text.substring(with: range))] : batched
        for edit in edits {
            mirrors = document.edit(edit.range, with: edit.text, changing: batched.isEmpty ? changing : edit.range, mirroring: mirroring)
        }
        (changing, batched) = (nil, [])
        return edits
    }

    mutating func mirror(composing: Bool) -> [TextEdit] {
        guard !mirroring, !composing else { return [] }
        defer { mirrors = [] }
        return mirrors
    }
}
