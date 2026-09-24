import SwiftUI

@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("TeXLocal", id: "main") {
            RootView()
                .environment(app)
                .onAppear {
                    delegate.app = app
                    applyAppearance(UserDefaults.standard.string(forKey: "appearance") ?? "system")
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
        }
    }
}

/// Quit waits for the open document to reach disk, and refuses — keeping the
/// window — when it cannot, rather than dropping the only copy of the edits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var app: AppModel?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let project = app?.project, project.dirty else { return .terminateNow }
        Task { @MainActor in
            sender.reply(toApplicationShouldTerminate: await project.flush())
        }
        return .terminateLater
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // Compiles run in their own process groups; nothing else stops them.
        Core.shared.killAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let project = app.project {
                WorkspaceView(project: project)
            } else {
                HomeView()
            }
        }
        .task { await app.refresh() }
        .sheet(isPresented: $app.showNewProject) { NewProjectSheet() }
        .alert("TeXLocal", isPresented: Binding(
            get: { app.alert != nil },
            set: { if !$0 { app.alert = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(app.alert ?? "")
        }
    }
}
