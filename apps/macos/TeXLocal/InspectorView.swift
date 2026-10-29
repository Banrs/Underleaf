import SwiftUI

struct InspectorView: View {
    let project: ProjectModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Project") {
                let texFiles = project.tree.nodes.flattened.filter { $0.kind == .tex }.map(\.path)
                let main = project.mainFile
                Picker("Main File", selection: Bindable(project).mainFile) {
                    ForEach(texFiles, id: \.self) { Text($0).tag(Optional($0)) }
                    if !texFiles.contains(where: { $0 == main }) { Text(main ?? "").tag(main) }
                }
                EnginePicker(project: project)
                Toggle("Shell Escape", detail: "Lets packages such as minted run programs. Only for projects you trust.",
                       isOn: Bindable(project).shellEscape)
                Toggle("Stop on First Error", detail: "Ends the build at its first error, rather than showing them all.",
                       isOn: Bindable(project).stopOnFirstError)
                Button("Clean Build Folder") { Task { await project.cleanBuildFolder() } }
            }
            .disabled(project.settings == nil)
            Section {
                Toggle("Live Preview", detail: app.canPreviewLive ? "Experimental. Updates the preview as you type, without compiling."
                           : Self.livePreviewMissing, isOn: Bindable(project).livePreview)
                .disabled(!project.canSwitchLivePreview)
                if !app.canPreviewLive {
                    SettingsLink { Text("Open Settings…") }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let livePreviewMissing: LocalizedStringKey = "Live Preview needs TeXpresso. Install it, or choose its folder in Settings."
}
