import SwiftUI

struct InspectorView: View {
    let project: ProjectModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Project") {
                let texFiles = project.tree.nodes.flattened.filter { $0.kind == .tex }.map(\.path)
                // The current value, even nil or unlisted, is a choice: a selection with no tag is a SwiftUI fault.
                let main = project.settings?.mainFile
                Picker("Main File", selection: Binding(get: { main }, set: { new in
                    if let new { Task.immediate { await project.patchSettings(.mainFile(new)) } }
                })) {
                    ForEach(texFiles, id: \.self) { Text($0).tag(Optional($0)) }
                    if !texFiles.contains(where: { $0 == main }) { Text(main ?? "").tag(main) }
                }
                EnginePicker(project: project)
                // iPadOS lets an app start no programs.
                #if os(macOS)
                toggle("Shell Escape", "Lets packages such as minted run programs. Only for projects you trust.", SettingsChange.shellEscape,
                       project.settings?.shellEscape ?? false)
                #endif
                toggle("Stop on First Error", "Ends the build at its first error, rather than showing them all.", SettingsChange.stopOnFirstError,
                       project.settings?.stopOnFirstError ?? false)
                Button("Clean Build Folder") { Task { await project.cleanBuildFolder() } }
            }
            .disabled(project.settings == nil)
            Section {
                Toggle("Live Preview", detail: app.canPreviewLive ? "Experimental. Updates the preview as you type, without compiling."
                           : Self.livePreviewMissing, isOn: Bindable(project).livePreview)
                .disabled(!project.canSwitchLivePreview)
                #if os(macOS)
                if !app.canPreviewLive {
                    HStack {
                        LinkButton(title: "Install Guide", url: Links.texpressoGuide)
                        Spacer()
                        SettingsLink { Text("Open Settings…") }
                    }
                }
                #endif
            }
        }
        .formStyle(.grouped)
    }

    #if os(macOS)
    private static let livePreviewMissing: LocalizedStringKey = "Live Preview needs TeXpresso. Install it, or choose its folder in Settings."
    #else
    private static let livePreviewMissing: LocalizedStringKey = "Live Preview needs TeX, which this build of TeXLocal doesn’t include."
    #endif

    private func toggle(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ change: @escaping (Bool) -> SettingsChange,
                        _ isOn: Bool) -> some View {
        Toggle(title, detail: detail, isOn: Binding(get: { isOn }, set: { on in Task.immediate { await project.patchSettings(change(on)) } }))
    }
}
