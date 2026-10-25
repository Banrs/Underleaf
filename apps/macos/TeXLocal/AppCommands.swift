import SwiftUI

struct AppCommands: Commands {
    let app: AppModel
    private var project: ProjectModel? { app.commandProject }

    private func items(_ commands: MenuCommand...) -> some View {
        ForEach(commands, id: \.self) { CommandItem(app: app, command: $0) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            items(.projectNew, .fileNew, .fileNewFolder, .projectOpen)
            Menu("Open Recent") {
                ForEach(app.recents) { recent in
                    Button(recent.name, systemImage: "text.document") { Task { await app.open(recent.id) } }
                    // A menu item's image shows only where the label style shows it.
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
            // As the document apps' Revert To, which lists Browse All Versions.
            Menu("Revert To") { items(.fileBrowseVersions) }
            Divider()
            items(.projectClose)
            Divider()
            ItemMenuItems(actions: app.mainWindowIsKey ? app.chosenItem : nil, trashShortcut: KeyboardShortcut(.delete))
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
        // A replacement group would lose the spelling and substitution checkmarks.
        TextEditingCommands()
        CommandGroup(before: .textEditing) { items(.projectSearch, .findUsages, .pdfFind) }
        CommandGroup(after: .pasteboard) {
            Divider()
            items(.editComment, .editShiftRight, .editShiftLeft, .editMoveLineUp, .editMoveLineDown, .editDuplicateLine, .editDeleteLine)
            Menu("Code Folding") { items(.editFold, .editUnfold, .editFoldAll, .editUnfoldAll) }
            Divider()
            items(.editRename)
        }
        // A submenu stays available while its items are dim (HIG Menus).
        CommandGroup(replacing: .textFormatting) {
            Menu("Font") { items(.editBold, .editItalic, .editUnderline) }
            Menu("Section Level") { SectionLevelItems(project: project) }
        }
        CommandGroup(replacing: .sidebar) {
            items(.viewToggleSidebar)
            Button(app.outlineOpen(of: project) ? "Hide File Outline" : "Show File Outline") { app.outlineCollapsed.toggle() }
                .disabled(project?.isLaTeX != true || project?.search.isSearching == true || !app.sidebarShown)
            Menu("Editor Layout") { WorkspaceLayoutPicker(app: app) }.disabled(project == nil)
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
                          inlineMathEnabled: app.isEnabledInMenuBar(.editMath, on: project)) { app.perform(.editMath, on: project) }
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
        // No help book: the default item would only say so.
        CommandGroup(replacing: .help) {
            items(.quickHelp)
            Divider()
            Link("Visit TeXLocal on GitHub", destination: Links.repository)
            Link("Report Issue", destination: Links.issues)
        }
    }
}

/// A menu item of its own, so a change to what it shows re-evaluates it and not the whole menu bar.
private struct CommandItem: View {
    let app: AppModel
    let command: MenuCommand

    var body: some View {
        let project = app.commandProject
        Button { app.perform(command, on: project) } label: {
            let title = app.title(command, on: project)
            // A menu item's image shows only with this style.
            if let symbol = command.style?.symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .labelStyle(.titleAndIcon)
        // ⌘N follows whether a project is open, not which window is key.
        .keyboardShortcut(app.shortcut(command, on: app.project))
        .disabled(!app.isEnabledInMenuBar(command, on: project))
    }
}

private struct LivePreviewItem: View {
    let app: AppModel

    var body: some View {
        let project = app.commandProject
        Toggle("Live Preview", isOn: project.map { Bindable($0).livePreview } ?? .constant(false))
            .disabled(project?.canSwitchLivePreview != true)
    }
}

/// The inspector's switches, dim with no project as the Engine picker is.
private struct BuildOptionItems: View {
    let app: AppModel

    var body: some View {
        let project = app.commandProject
        option("Shell Escape", project, \.shellEscape, SettingsChange.shellEscape)
        option("Stop on First Error", project, \.stopOnFirstError, SettingsChange.stopOnFirstError)
    }

    private func option(_ title: LocalizedStringKey, _ project: ProjectModel?, _ setting: KeyPath<ProjectSettings, Bool>,
                        _ change: @escaping (Bool) -> SettingsChange) -> some View {
        let isOn = project?.settings?[keyPath: setting]
        return Toggle(title, isOn: Binding(get: { isOn ?? false }, set: { on in
            if let project { Task.immediate { await project.patchSettings(change(on)) } }
        }))
        .disabled(isOn == nil)
    }
}

private struct SetMainFileItem: View {
    let app: AppModel

    var body: some View {
        let project = app.commandProject
        Button("Set as Main File") {
            if let project, let path = project.openPath { Task { await project.patchSettings(.mainFile(path)) } }
        }
        .disabled(project?.isLaTeX != true || project?.openPath == project?.settings?.mainFile)
    }
}
