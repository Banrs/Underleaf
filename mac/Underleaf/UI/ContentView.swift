import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
        } detail: {
            EditorWebView(controller: model.editor)
                .ignoresSafeArea()               // panes go edge-to-edge under the toolbar
                .navigationTitle(model.currentProjectId ?? "Underleaf")
                .navigationSubtitle(subtitle)
        }
        .toolbar { toolbarContent }
        // Native chrome matches the system automatically — no CSS traffic-light math.
        .onChange(of: colorScheme) { _, new in model.applyDark(new == .dark) }
        .onAppear { model.applyDark(colorScheme == .dark) }
    }

    private var subtitle: String {
        model.dirty ? "Unsaved" : (model.openPath.map { ($0 as NSString).lastPathComponent } ?? "")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Undo")
            Button { model.editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("Redo")
        }
        ToolbarItemGroup(placement: .principal) {
            Button { model.editor.format("bold") } label: { Image(systemName: "bold") }.help("Bold")
            Button { model.editor.format("italic") } label: { Image(systemName: "italic") }.help("Italic")
            Button { model.editor.format("math") } label: { Image(systemName: "sum") }.help("Inline math")
            Divider()
            Button { model.editor.format("comment") } label: { Image(systemName: "text.bubble") }.help("Comment")
            Button { model.editor.find() } label: { Image(systemName: "magnifyingglass") }.help("Find")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.compiling {
                ProgressView().controlSize(.small)
            }
            Button { model.compile() } label: {
                Label("Compile", systemImage: "play.fill")
            }
            .disabled(!model.texAvailable || model.compiling)
            .keyboardShortcut(.return, modifiers: .command)
            .help(model.texAvailable ? "Compile (⌘↩)" : "No TeX distribution found")
        }
    }
}
