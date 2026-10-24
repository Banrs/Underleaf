import SwiftUI

// A setting with a line under its title saying what it does.
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

struct LinkButton: View {
    @Environment(\.openURL) private var openURL
    let title: LocalizedStringKey
    let url: URL

    var body: some View { Button(title) { openURL(url) } }
}

enum PDFPaper: String, CaseIterable, Identifiable {
    case white, dark, auto

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .white: "White"
        case .dark: "Dark"
        case .auto: "Match Appearance"
        }
    }

    func isDark(onDark appearance: Bool) -> Bool { self == .dark || (self == .auto && appearance) }
}
