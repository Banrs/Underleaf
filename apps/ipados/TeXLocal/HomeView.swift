import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            List(app.projects) { project in
                Button(project.name) { Task { await app.open(project.id) } }
            }
            .navigationTitle("Projects")
        }
    }
}
