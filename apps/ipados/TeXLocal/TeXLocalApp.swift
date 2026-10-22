import SwiftUI

@main
struct TeXLocalApp: App {
    @State private var app = AppModel()
    /// In-app settings, a sheet: the menu's Settings item is for the app's page in the Settings app (HIG, The menu bar).
    @State private var settingsShown = false

    var body: some Scene {
        WindowGroup {
            RootView(settingsShown: $settingsShown).environment(app)
        }
        // The menu bar has the Mac's menus, as iPadOS's should (HIG, The menu bar).
        .commands {
            AppCommands(app: app)
            // Beneath iPadOS's own Settings item and its ⌘,, which open the app's page in the Settings app.
            CommandGroup(after: .appSettings) { Button("App Settings…") { settingsShown = true } }
            CommandGroup(replacing: .help) {
                Link("Visit TeXLocal on GitHub", destination: Links.repository)
                Link("Report Issue", destination: Links.issues)
            }
        }
    }
}
