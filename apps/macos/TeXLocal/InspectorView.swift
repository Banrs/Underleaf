import SwiftUI

/// Project build options in AppKit's inspector column.
struct InspectorView: View {
    let project: ProjectModel

    var body: some View {
        Form {
            if let settings = project.settings {
                Section("Project") {
                    let texFiles = project.tree.flattened.filter { !$0.isDirectory && isLaTeXFile($0.path) }.map(\.path)
                    picker("Main File", settings.mainFile, texFiles.map { ($0, $0) }, set: project.setMainFile)
                    picker("Engine", settings.engine, texEngines, set: project.setEngine)
                    toggle("Shell Escape", "Lets packages such as minted run programs. Only enable this for projects you trust.",
                           settings.shellEscape, set: project.setShellEscape)
                    toggle("Stop on First Error", "Ends the build at its first error.",
                           settings.stopOnFirstError, set: project.setStopOnFirstError)
                }
                if let path = project.openPath {
                    Section("Document") {
                        let sections = project.outline.filter { $0.file == path }.count
                        LabeledContent("Location", value: path)
                        if let counts = project.counts {
                            LabeledContent("Lines", value: counts.lines.formatted())
                        }
                        if sections > 0 {
                            LabeledContent("Sections", value: sections.formatted())
                        }
                    }
                }
            } else {
                ProgressView("Loading Project Settings…")
            }
        }
        .scenePadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A main file missing from the tree or an unrecognized engine remains selectable.
    private func picker(_ title: String, _ value: String, _ options: [(String, String)],
                        set: @escaping (String) async -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: { new in Task { await set(new) } })) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            if !options.contains(where: { $0.0 == value }) { Text(value).tag(value) }
        }
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Bool,
                        set: @escaping (Bool) async -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { on in Task { await set(on) } }))
            .help(detail)
            .accessibilityHint(detail)
    }
}
