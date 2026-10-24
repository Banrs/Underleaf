import SwiftUI

/// Not focusable, or it takes the source's keyboard as it shows. Maths the core can't draw shows as its TeX, in red.
struct MathView: View {
    var tex = ""
    var em: CGFloat = 0
    var image: NSImage?

    /// Longer maths is shown smaller: wider than this.
    var widest: CGFloat = 560

    var body: some View {
        let line = (em * 1.2).rounded(.up)
        Group {
            if let image {
                let scale = min(1, widest / max(image.size.width, 1))
                Image(drawn: image)
                    .renderingMode(.template)
                    .resizable()
                    .foregroundStyle(.primary)
                    .frame(width: (image.size.width * scale).rounded(.up), height: (image.size.height * scale).rounded(.up))
            } else {
                Text(verbatim: tex).font(.system(size: em)).foregroundStyle(.red).lineLimit(1).frame(maxWidth: widest)
            }
        }
        .frame(minWidth: line, minHeight: line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Math Preview")
        .accessibilityValue(tex)
        .focusable(false)
        .allowsHitTesting(false)
        .padding()
    }
}

extension Image {
    init(drawn image: NSImage) {
        self.init(nsImage: image)
    }
}
