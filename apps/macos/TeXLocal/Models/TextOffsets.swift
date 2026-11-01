import AppKit

extension NSTextContentManager {
    func offset(of location: any NSTextLocation) -> Int { offset(from: documentRange.location, to: location) }

    func textRange(of range: NSRange) -> NSTextRange? {
        guard let start = location(documentRange.location, offsetBy: range.location),
              let end = location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
