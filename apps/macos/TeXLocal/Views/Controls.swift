import SwiftUI

extension Toggle where Label == TupleView<(Text, Text)> {
    init(_ title: LocalizedStringKey, detail: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title); Text(detail) }
    }
}

extension Picker where Label == TupleView<(Text, Text)> {
    init(_ title: LocalizedStringKey, detail: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(title); Text(detail) }
    }
}

extension NSPasteboard {
    func replaceContents(with string: String) {
        clearContents()
        setString(string, forType: .string)
    }
}
