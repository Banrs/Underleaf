import SwiftUI
import UIKit

/// The Mac's Settings panes as sections of one sheet, with Done (HIG, Sheets).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Projects Folder", value: "On My iPad › TeXLocal")
                    // Files opens at the app's folder from this scheme.
                    Button("Show in Files") {
                        if let url = URL(string: "shareddocuments://" + Core.libraryFolder.path(percentEncoded: true)) { openURL(url) }
                    }
                } footer: {
                    Text("New and imported projects are kept here.")
                }
                NewProjectSettings()
                EditorSettings()
                Section("Compiling") { CompilingToggles() }
                Section("PDF") { PaperPicker() }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
