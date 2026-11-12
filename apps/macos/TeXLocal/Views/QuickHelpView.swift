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

struct ReferencePictureView: View {
    let picture: ReferencePicture

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Image(nsImage: picture.image)
            .colorInverted(picture.darkPaper)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.separator) }
            .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder func colorInverted(_ inverted: Bool) -> some View {
        // As the PDF view shows dark paper.
        if inverted { colorInvert().hueRotation(.degrees(180)) } else { self }
    }
}
