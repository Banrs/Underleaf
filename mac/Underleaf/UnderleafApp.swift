import SwiftUI

@main
struct UnderleafApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
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
        .windowToolbarStyle(.unified)   // one unified title+toolbar row (traffic lights + toolbar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { /* TODO: prompt + ProjectStore.createProject */ }
                    .keyboardShortcut("n")
            }
        }
    }
}
