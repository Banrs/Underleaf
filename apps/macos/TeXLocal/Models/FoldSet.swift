import Foundation

struct FoldSet: Equatable {
    private(set) var ranges: [NSRange]

    init(_ ranges: [NSRange] = []) { self.ranges = Set(ranges).sorted { $0.location < $1.location } }

    var isEmpty: Bool { ranges.isEmpty }

    func hides(_ offset: Int) -> Bool { ranges.contains { $0.contains(offset) } }

    func headers(in document: SourceDocument) -> [Int: NSRange] {
        Dictionary(ranges.map { (document.line(at: $0.location - 1), $0) }) { first, _ in first }
    }

    func caret(on line: Int, hiding selection: NSRange, in document: SourceDocument) -> NSRange? {
        guard ranges.contains(where: { $0.contains(selection.location) || NSIntersectionRange($0, selection).length > 0 }) else { return nil }
        return .caret(max(document.lineStart(line), document.lineStart(line + 1) - 1))
    }

    mutating func edited(_ old: NSRange, delta: Int) -> Bool {
        let count = ranges.count
        ranges = ranges.compactMap { fold in
            if NSMaxRange(old) < fold.location { return NSRange(location: fold.location + delta, length: fold.length) }
            return old.location >= NSMaxRange(fold) ? fold : nil
        }
        return ranges.count < count
    }

    mutating func moved(from old: NSRange, to new: NSRange, stepping: Bool) -> NSRange? {
        if stepping, new.length == 0, old.length == 0, let fold = ranges.first(where: { $0.contains(new.location) }) {
            if old.location == fold.location - 1 { return .caret(NSMaxRange(fold)) }
            if old.location == NSMaxRange(fold) { return .caret(fold.location - 1) }
        }
        ranges.removeAll { $0.contains(new.location) || $0.contains(NSMaxRange(new)) && NSMaxRange(new) > $0.location }
        return nil
    }
}

extension Fold {
    func hidden(in document: SourceDocument, length: Int) -> NSRange {
        let start = document.lineStart(line + 1)
        let end = self.end < document.lineCount ? document.lineStart(self.end + 1) : length
        return NSRange(location: start, length: end - start)
    }
}
