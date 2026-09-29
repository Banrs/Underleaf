import SwiftUI

/// The inspector: the project's build settings, then facts about the open file and
/// its build.
struct InspectorView: View {
    let project: ProjectModel

    var body: some View {
        Form {
            Section("Project") {
                let texFiles = project.tree.flattened.filter { !$0.isDirectory && $0.path.hasSuffix(".tex") }.map(\.path)
                picker("Main File", project.settings?.mainFile, texFiles.map { ($0, $0) }, set: project.setMainFile)
                picker("Engine", project.settings?.engine, texEngines, set: project.setEngine)
                toggle("Shell Escape", "Lets packages such as minted run programs. Only for projects you trust.",
                       project.settings?.shellEscape ?? false, set: project.setShellEscape)
                toggle("Stop on First Error", "Ends the build at its first error, rather than showing them all.",
                       project.settings?.stopOnFirstError ?? false, set: project.setStopOnFirstError)
            }
            // Settings arrive from the core after the project opens.
            .disabled(project.settings == nil)
            if let path = project.openPath {
                Section("Document") {
                    LabeledContent("Name", value: (path as NSString).lastPathComponent)
                    LabeledContent("Folder", value: folder(of: path))
                    if let counts = project.counts {
                        LabeledContent("Words", value: counts.words.formatted())
                        LabeledContent("Lines", value: counts.lines.formatted())
                    }
                    if !project.outline.isEmpty {
                        LabeledContent("Sections", value: project.outline.count.formatted())
                    }
                }
            }
            Section("Build") {
                if let result = project.result {
                    LabeledContent("Last Build", value: result.stopped ? "Stopped" : result.ok ? "Succeeded" : "Failed")
                    LabeledContent("Duration", value: result.durationText)
                    LabeledContent("Errors", value: project.errorCount.formatted())
                    LabeledContent("Warnings", value: project.warningCount.formatted())
                } else {
                    LabeledContent("Last Build", value: project.pdfVersion > 0 ? "None Yet" : "None")
                }
                if let freshness = project.pdfFreshness {
                    Label(freshness.title, systemImage: freshness.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
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

    private func folder(of path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? project.id : dir
    }
}
