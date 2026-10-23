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
                    // macOS 27 hides a menu item's image unless the label style shows it.
                    .labelStyle(.titleAndIcon)
                }
                Divider()
                Button("Clear Menu") { app.recentProjects = [] }
                    .disabled(app.recents.isEmpty)
            }
            Divider()
            items(.fileUpload)
        }
        CommandGroup(after: .saveItem) {
            items(.fileSave)
            Divider()
            items(.projectClose)
            #if os(macOS)
            Divider()
            ItemMenuItems(actions: app.mainWindowIsKey ? app.chosenItem : nil, trashShortcut: KeyboardShortcut(.delete))
                .labelStyle(.titleAndIcon)
            #endif
        }
        CommandGroup(replacing: .importExport) {
            items(.pdfSave, .projectExport)
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
        CommandGroup(before: .textEditing) { items(.projectSearch, .pdfFind) }
        CommandGroup(after: .pasteboard) {
            Divider()
            items(.editComment, .editShiftRight, .editShiftLeft, .editMoveLineUp, .editMoveLineDown)
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
            items(.viewToggleSource, .viewTogglePDF, .viewToggleInspector, .viewToggleLogs, .viewToggleWordCount)
            Divider()
            items(.viewZoomIn, .viewZoomOut, .viewActualSize, .viewFitWidth, .viewFitPage)
        }
        CommandMenu("Go") {
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
            SetMainFileItem(app: app)
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
            // macOS 27 shows a menu item's image only with this style.
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
