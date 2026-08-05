import SwiftUI

@main
struct UnderleafApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // A single window: every ContentView shares the one WKWebView in
        // AppModel, and an NSView can only live in one window at a time.
        Window("Underleaf", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    // Open the most-recent project on launch.
                    if model.currentProjectId == nil, let first = model.projects.first {
                        model.openProject(first.id)
                    }
                }
        }
        .windowToolbarStyle(.unified)
    }
}
