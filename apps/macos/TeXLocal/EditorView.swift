import SwiftUI

/// Hosts the app's one editor web view, and keeps its appearance in step with
/// the system and Settings.
struct EditorView: NSViewRepresentable {
    let bridge: EditorBridge
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editorPalette") private var palette = "onedark"
    @AppStorage("editorFont") private var font = "system"
    @AppStorage("editorFontSize") private var fontSize = 14

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
        let (theme, palette, font, fontSize) = (colorScheme == .dark ? "dark" : "light", palette, font, fontSize)
        Task { await bridge.setAppearance(theme: theme, palette: palette, font: font, fontSize: fontSize) }
    }

    /// The web view outlives any one container (it moves between projects),
    /// so it is re-parented rather than recreated.
    private func attach(to container: NSView) {
        let web = bridge.webView
        guard web.superview !== container else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
