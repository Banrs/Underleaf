import SwiftUI

/// The inspector: the project's build settings. The file's counts and the last build
/// show in the status bar and the build panel, so it doesn't repeat them.
struct InspectorView: View {
    let project: ProjectModel

    var body: some View {
        Form {
            Section("Project") {
                let texFiles = project.tree.flattened.filter { !$0.isDirectory && isLaTeXFile($0.path) }.map(\.path)
                picker("Main File", project.settings?.mainFile, texFiles.map { ($0, $0) }, set: project.setMainFile)
                picker("Engine", project.settings?.engine, texEngines, set: project.setEngine)
                toggle("Shell Escape", "Lets packages such as minted run programs. Only for projects you trust.",
                       project.settings?.shellEscape ?? false) { _ = await project.patchSettings(["shellEscape": $0]) }
                toggle("Stop on First Error", "Ends the build at its first error, rather than showing them all.",
                       project.settings?.stopOnFirstError ?? false) { _ = await project.patchSettings(["stopOnFirstError": $0]) }
            }
            // Settings arrive from the core after the project opens.
            .disabled(project.settings == nil)
        }
        .formStyle(.grouped)
    }

    /// The current value is always a choice, before the settings come (nil) or the
    /// main file is in the file list: a selection with no tag is a SwiftUI fault.
    private func picker(_ title: String, _ value: String?, _ options: [(String, String)],
                        set: @escaping (String) async -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: { new in if let new { Task { await set(new) } } })) {
            ForEach(options, id: \.0) { Text($0.1).tag(Optional($0.0)) }
            if !options.contains(where: { $0.0 == value }) { Text(value ?? "").tag(value) }
        }
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Bool,
                        set: @escaping (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in Task { await set(on) } })) {
            Text(title)
            Text(detail)
        }
    }
}
