import SwiftUI

struct QuickHelpView: View {
    let help: QuickHelp
    let picture: ReferencePicture?
    let font: NSFont
    let jump: (FilePlace) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(help.title).font(Font(font))
            if let picture { ReferencePictureView(picture: picture) }
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
