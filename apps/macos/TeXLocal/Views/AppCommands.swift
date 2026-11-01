import SwiftUI

struct AppCommands: Commands {
    let app: AppModel
    private var project: ProjectModel? { app.main?.shownProject }

    private func items(_ commands: MenuCommand...) -> some View {
        ForEach(commands, id: \.self) { CommandItem(app: app, command: $0) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            items(.projectNew, .fileNew, .fileNewFolder, .projectOpen)
            Menu("Open Recent") {
                ForEach(app.recents) { recent in
                    Button(recent.name, systemImage: "text.document") { Task { await app.front.open(recent.id) } }
                    .labelStyle(.titleAndIcon)
                }
                Divider()
                Button("Clear Menu") { app.recentProjects = [] }
                    .disabled(app.recents.isEmpty)
            }
            items(.openQuickly)
            Divider()
            items(.fileUpload)
        }
        CommandGroup(after: .saveItem) {
            items(.fileSave, .fileSaveVersion)
            Menu("Revert To") { items(.fileBrowseVersions) }
            Divider()
            items(.projectClose)
            Divider()
            ItemMenuItems(actions: app.main?.chosenItem, trashShortcut: KeyboardShortcut(.delete))
                .labelStyle(.titleAndIcon)
        }
        CommandGroup(replacing: .importExport) {
            items(.pdfSave, .pdfOpen, .projectExport, .projectExportArxiv)
            Divider()
            if let project, let url = project.buildPDF {
                ShareLink(item: url)
            } else {
                Button("Share…", systemImage: "square.and.arrow.up") {}.labelStyle(.titleAndIcon).disabled(true)
            }
        }
        CommandGroup(replacing: .printItem) { items(.filePrint) }
        TextEditingCommands()
        CommandGroup(before: .textEditing) { items(.projectSearch, .findUsages, .pdfFind) }
        CommandGroup(after: .pasteboard) {
            Divider()
            items(.editComment, .editShiftRight, .editShiftLeft, .editMoveLineUp, .editMoveLineDown, .editDuplicateLine, .editDeleteLine)
            Menu("Code Folding") { items(.editFold, .editUnfold, .editFoldAll, .editUnfoldAll) }
            Divider()
            items(.editRename)
        }
        CommandGroup(replacing: .textFormatting) {
            Menu("Font") { items(.editBold, .editItalic, .editUnderline) }
            Menu("Section Level") { SectionLevelItems(project: project) }
        }
        CommandGroup(replacing: .sidebar) {
            Menu("Navigators") {
                ForEach(Navigator.allCases, id: \.self) { navigator in
                    Button(navigator.title) { project?.showNavigator(navigator) }
                        .keyboardShortcut(navigator.shortcut)
                }
            }
            .disabled(project == nil)
            Menu("Editor Layout") { if let window = app.main { WorkspaceLayoutPicker(window: window) } }.disabled(project == nil)
            items(.viewToggleSource, .viewTogglePDF, .viewToggleInspector, .viewToggleLogs, .viewToggleWordCount)
            Divider()
            items(.viewZoomIn, .viewZoomOut, .viewActualSize, .viewFitWidth, .viewFitPage)
        }
        CommandMenu("Go") {
            items(.goBack, .goForward)
            Divider()
            items(.editGotoLine, .pdfGotoPage)
            Divider()
            items(.jumpToDefinition)
            Divider()
            items(.syncForward, .syncInverse)
            Divider()
            items(.issueNext, .issuePrevious)
        }
        CommandMenu("Insert") {
            MathMenuItems(project: project, shortcut: MenuCommand.editMath.shortcut,
                          inlineMathEnabled: app.isEnabledInMenuBar(.editMath, on: project)) { app.main?.perform(.editMath, on: project) }
            Divider()
            InsertMenuItems(project: project)
        }
        CommandMenu("Compile") {
            items(.compileRun, .compileStop, .compileClean)
            Divider()
            Toggle("Compile Automatically", isOn: Bindable(app).autoCompile)
            LivePreviewItem(app: app)
            Divider()
            Menu("Engine") { EnginePicker(project: project).pickerStyle(.inline).labelsHidden() }
            BuildOptionItems(app: app)
            SetMainFileItem(app: app)
        }
        CommandGroup(replacing: .singleWindowList) {
            Button("Projects") { app.showHome() }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            items(.quickHelp)
            Divider()
            Link("Visit TeXLocal on GitHub", destination: Links.repository)
            Link("Report Issue", destination: Links.issues)
        }
    }
}

private struct CommandItem: View {
    let app: AppModel
    let command: MenuCommand

    var body: some View {
        let window = app.main, project = window?.shownProject
        Button { (window ?? app.front).perform(command, on: project) } label: {
            let title = window?.title(command, on: project) ?? command.title
            if let symbol = command.style?.symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .labelStyle(.titleAndIcon)
        .keyboardShortcut(app.shortcut(command, on: window?.project))
        .disabled(!app.isEnabledInMenuBar(command, on: project))
    }
}

private struct LivePreviewItem: View {
    let app: AppModel

    var body: some View {
        let project = app.main?.shownProject
        Toggle("Live Preview", isOn: project.map { Bindable($0).livePreview } ?? .constant(false))
            .disabled(project?.canSwitchLivePreview != true)
    }
}

private struct BuildOptionItems: View {
    let app: AppModel

    var body: some View {
        let project = app.main?.shownProject
        option("Shell Escape", project, \.shellEscape)
        option("Stop on First Error", project, \.stopOnFirstError)
    }

    private func option(_ title: LocalizedStringKey, _ project: ProjectModel?,
                        _ setting: ReferenceWritableKeyPath<ProjectModel, Bool>) -> some View {
        Toggle(title, isOn: project.map { Bindable($0)[dynamicMember: setting] } ?? .constant(false))
            .disabled(project?.settings == nil)
    }
}

private struct SetMainFileItem: View {
    let app: AppModel

    var body: some View {
        let project = app.main?.shownProject
        Button("Set as Main File") {
            if let project, let path = project.openPath { project.mainFile = path }
        }
        .disabled(project?.isLaTeX != true || project?.openPath == project?.mainFile)
    }
}
