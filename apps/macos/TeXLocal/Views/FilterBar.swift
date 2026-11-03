import SwiftUI

/// A filter for the pane above it, for the pane's bottom accessory: a search field with an optional control on each side.
struct FilterBar<Leading: View, Trailing: View>: View {
    @Binding var text: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            leading
            SearchField(text: $text, prompt: String(localized: "Filter"))
            trailing
        }
        // Small, so that with AppKit's insets the bar is 38 pt, level with the panes' bars beside it.
        .controlSize(.small)
    }
}

extension FilterBar where Leading == EmptyView, Trailing == EmptyView {
    init(text: Binding<String>) { self.init(text: text, leading: { EmptyView() }, trailing: { EmptyView() }) }
}
