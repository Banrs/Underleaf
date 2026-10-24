import SwiftUI

/// Xcode's Quick Help: the name in the editor's font, what it is beneath, and a way to where it is defined.
struct QuickHelpView: View {
    let help: QuickHelp
    let font: NSFont
    let jump: (Place) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(help.title).font(Font(font))
            if !help.detail.isEmpty { Text(help.detail) }
            if let place = help.place {
                Button("Jump to Definition") { jump(place) }
                    .buttonStyle(.link)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
    }
}
