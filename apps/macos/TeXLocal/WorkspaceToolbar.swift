import SwiftUI

struct WorkspaceToolbar: CustomizableToolbarContent {
    @Bindable var app: AppModel
    let project: ProjectModel

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "sidebar", placement: .navigation) {
            Button("Sidebar", systemImage: "sidebar.left") { app.sidebarShown.toggle() }
                .help(app.title(.viewToggleSidebar, on: project))
        }
        ToolbarItem(id: "projects", placement: .navigation) {
            Button("Projects", systemImage: "chevron.backward") { app.perform(.projectClose, on: project) }
                .help("Return to Projects")
                .disabled(project.closed)
        }
        ToolbarItem(id: "format") {
            Menu("Format", systemImage: "textformat") {
                ForEach([MenuCommand.editBold, .editItalic, .editUnderline], id: \.self) { command in
                    Button(command.title, systemImage: command.style!.symbol) { app.perform(command, on: project) }
                }
                Divider()
                SectionLevelItems(project: project)
            }
            .disabled(!project.sourceToolsEnabled || project.closed)
        }
        .visibilityPriority(.low)
        ToolbarItem(id: "math") {
            Menu("Math", systemImage: "radicand.squareroot") {
                MathMenuItems(project: project) { app.perform(.editMath, on: project) }
            }
            .disabled(!project.sourceToolsEnabled || project.closed)
        }
        .visibilityPriority(.low)
        ToolbarItem(id: "insert") {
            Menu("Insert", systemImage: "plus") { InsertMenuItems(project: project) }
                .disabled(!project.sourceToolsEnabled || project.closed)
        }
        .visibilityPriority(.low)
        ToolbarSpacer(.fixed)
        ToolbarItem(id: "zoom") {
            ZoomControl(pdf: project.pdf)
                .disabled(!project.hasPDF || project.closed)
        }
        .hidden(!app.showPDF)
        .visibilityPriority(.low)
        ToolbarItem(id: "compile") {
            Button {
                app.perform(project.compiling ? .compileStop : .compileRun, on: project)
            } label: {
                HStack {
                    if project.compiling { ProgressView().controlSize(.small) }
                    Text(project.compiling ? "Stop" : "Compile")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(project.closed || !app.isEnabled(project.compiling ? .compileStop : .compileRun, on: project))
            .help(project.compiling ? "Stop the build" : "Compile the project")
        }
        .visibilityPriority(.high)
        ToolbarSpacer(.fixed)
        ToolbarItem(id: "layout") {
            Menu("Editor Layout", systemImage: "rectangle.split.2x1") { WorkspaceLayoutPicker(app: app) }
                .help("Choose Source Only, Source & PDF, or PDF Only")
        }
        .visibilityPriority(.high)
        ToolbarItem(id: "inspector") {
            Button("Inspector", systemImage: "sidebar.right") { app.inspectorShown.toggle() }
                .help(app.title(.viewToggleInspector, on: project))
        }
        ToolbarItem(id: "share") {
            if let url = project.buildPDF {
                ShareLink(item: url).disabled(project.closed)
            } else {
                Button("Share PDF", systemImage: "square.and.arrow.up") {}.disabled(true)
            }
        }
        .defaultCustomization(.hidden)
    }
}

struct WorkspaceLayoutPicker: View {
    @Bindable var app: AppModel

    var body: some View {
        Picker("Editor Layout", selection: $app.layout) {
            Text("Source Only").tag(WorkspaceLayout.source)
            Text("Source & PDF").tag(WorkspaceLayout.split)
            Text("PDF Only").tag(WorkspaceLayout.pdf)
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

private struct ZoomControl: View {
    let pdf: PDFController

    var body: some View {
        ControlGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { pdf.zoom(in: false) }
                .disabled(!pdf.canZoomOut)
                .help("Zoom out of the PDF")
            Menu {
                ScaleMenuItems(pdf: pdf)
            } label: {
                ZStack {
                    Text(pdf.widestZoomLabel).hidden()
                    Text(pdf.zoomLabel)
                }
                .monospacedDigit()
            }
            .accessibilityLabel("Zoom")
            .help("Choose a zoom level")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { pdf.zoom(in: true) }
                .disabled(!pdf.canZoomIn)
                .help("Zoom in on the PDF")
        }
        .fixedSize()
    }
}
