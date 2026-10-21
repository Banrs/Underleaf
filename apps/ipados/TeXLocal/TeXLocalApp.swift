import SwiftUI

@main
struct TeXLocalApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView().environment(app)
        }
    }
}
