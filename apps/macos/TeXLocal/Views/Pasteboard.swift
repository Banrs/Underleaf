import AppKit

extension NSPasteboard {
    func replaceContents(with string: String) {
        clearContents()
        setString(string, forType: .string)
    }
}
