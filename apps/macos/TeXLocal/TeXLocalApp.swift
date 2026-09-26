import SwiftUI

@main
struct TeXLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("TeXLocal", id: "main") {
            RootView()
                .environment(app)
                .onAppear { delegate.app = app }
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            AppCommands(app: app)
            // Show/Hide Toolbar and Customize Toolbar… in the View menu.
            ToolbarCommands()
            // The app has no help book; the default item only said so.
            CommandGroup(replacing: .help) {
                Link("TeXLocal on GitHub", destination: URL(string: "https://github.com/Banrs/Underleaf")!)
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

/// Quit waits for the open document to reach disk, and refuses — keeping the
/// window — when it cannot, rather than dropping the only copy of the edits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A save in flight counts: it has cleared `dirty` before its write
        // is on disk.
        guard let project = app?.project, project.dirty || project.saving else { return .terminateNow }
        Task { @MainActor in
            sender.reply(toApplicationShouldTerminate: await project.flush())
        }
        return .terminateLater
    }

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
        // One minimum for the window whatever it shows, with room for every
        // column at its own: navigator 200, source and PDF together 441,
        // inspector 220. A minimum that changed with the content — raised as a project
        // opened — landed mid-layout on the split view, whose constraint
        // passes then looped until AppKit threw.
        .frame(minWidth: 960, minHeight: 600)
        .task {
            await app.refresh()
            // `open TeXLocal.app --args -openProject <id>` opens a project at
            // launch; launch arguments land in UserDefaults' argument domain
            // for this run only.
            if let id = UserDefaults.standard.string(forKey: "openProject"), app.project == nil {
                await app.open(id)
            }
        }
        .sheet(isPresented: $app.showNewProject) { NewProjectSheet() }
        // The title says what happened, as the HIG asks; the app's name
        // told nothing.
        .alert(app.alert ?? "", isPresented: Binding(
            get: { app.alert != nil },
            set: { if !$0 { app.alert = nil } }
        )) {
            Button("OK") {}
        }
    }
}
