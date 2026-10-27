import SwiftUI

struct InspectorView: View {
    let project: ProjectModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Project") {
                let texFiles = project.tree.nodes.flattened.filter { $0.kind == .tex }.map(\.path)
                let main = project.settings?.mainFile
                Picker("Main File", selection: Binding(get: { main }, set: { new in
                    if let new { Task.immediate { await project.patchSettings(SettingsPatch(mainFile: new)) } }
                })) {
                    ForEach(texFiles, id: \.self) { Text($0).tag(Optional($0)) }
                    if !texFiles.contains(where: { $0 == main }) { Text(main ?? "").tag(main) }
                }
                EnginePicker(project: project)
                toggle("Shell Escape", "Lets packages such as minted run programs. Only for projects you trust.",
                       project.settings?.shellEscape ?? false) { SettingsPatch(shellEscape: $0) }
                toggle("Stop on First Error", "Ends the build at its first error, rather than showing them all.",
                       project.settings?.stopOnFirstError ?? false) { SettingsPatch(stopOnFirstError: $0) }
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

    private func toggle(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ isOn: Bool,
                        _ change: @escaping (Bool) -> SettingsPatch) -> some View {
        Toggle(title, detail: detail, isOn: Binding(get: { isOn }, set: { on in Task.immediate { await project.patchSettings(change(on)) } }))
    }
}
