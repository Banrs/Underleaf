import SwiftUI

/// The workspace's tools: Back leading the title, the editing tools, then the PDF's and
/// Compile, the window's one prominent action (HIG, Toolbars), and the toggles. Undo, Redo,
/// Bold, Italic, Underline, Share and the insert buttons are there to add. Back, Compile and
/// the toggles stay.
struct WorkspaceToolbar: CustomizableToolbarContent {
    let app: AppModel
    let project: ProjectModel
    @Binding var pdfShown: Bool
    @Binding var inspectorShown: Bool
    /// Aa's popover.
    @Binding var formatShown: Bool

    private var pdf: PDFController { project.pdf }
    private static let buttonTemplates = (referenceTemplates + insertTemplates + listTemplates).filter { $0.symbol != nil }

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "back", placement: .navigation) {
            Button("Projects", systemImage: "chevron.backward") { app.perform(.projectClose, on: project) }
                .help("Back to Projects")
        }
        .customizationBehavior(.disabled)
        // Whatever has the keyboard, as the menu's Undo.
        ToolbarItem(id: "undo", showsByDefault: false) {
            Button("Undo", systemImage: "arrow.uturn.backward") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
        }
        ToolbarItem(id: "redo", showsByDefault: false) {
            Button("Redo", systemImage: "arrow.uturn.forward") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
        }
        ToolbarItem(id: "format") {
            Button("Format", systemImage: "textformat") { formatShown.toggle() }
                .help("Format")
                .popover(isPresented: $formatShown, arrowEdge: .bottom) {
                    FormatPanel(app: app, project: project) { formatShown = false }
                }
                .disabled(!project.isLaTeX)
        }
        ForEach([MenuCommand.editBold, .editItalic, .editUnderline], id: \.self) { command in
            ToolbarItem(id: command.rawValue, showsByDefault: false) {
                Button(command.title, systemImage: command.symbol ?? "") { app.perform(command, on: project) }
                    .help(command.title)
                    .disabled(!project.isLaTeX)
            }
        }
        ToolbarItem(id: "math") {
            Menu("Math", systemImage: "radicand.squareroot") {
                MathMenuItems(project: project) { app.perform(.editMath, on: project) }
            }
            .menuIndicator(.hidden)
            .help("Math")
            .disabled(!project.isLaTeX)
        }
        // Notes' ellipsis, which means More (HIG, Icons), named Insert: it holds the menu bar's Insert.
        ToolbarItem(id: "insert") {
            Menu("Insert", systemImage: "ellipsis") { InsertMenuItems(project: project) }
                .menuIndicator(.hidden)
                .help("Insert")
                .disabled(!project.isLaTeX)
        }
        ForEach(Self.buttonTemplates, id: \.title) { template in
            ToolbarItem(id: "template." + template.title, showsByDefault: false) {
                Button(template.title, systemImage: template.symbol ?? "") { project.insert(template) }
                    .help(template.title)
                    .disabled(!project.isLaTeX)
            }
        }
        ToolbarSpacer(.flexible)
        ToolbarItem(id: "zoom") {
            ZoomControl(app: app, project: project)
        }
        .hidden(!pdfShown)
        ToolbarItem(id: "share", showsByDefault: false) {
            if let url = project.pdfURL {
                ShareLink(item: url).help("Share PDF")
            } else {
                Button("Share", systemImage: "square.and.arrow.up") {}.disabled(true)
            }
        }
        ToolbarItem(id: "compile") {
            CompileButton(app: app, project: project)
        }
        .customizationBehavior(.disabled)
        ToolbarSpacer(.fixed)
        // A document's symbol: the PDF is the source's peer, not a sidebar or an inspector.
        ToolbarItem(id: "togglePDF") {
            Toggle("PDF", systemImage: "richtext.page", isOn: $pdfShown)
                .help(pdfShown ? "Hide PDF" : "Show PDF")
        }
        .customizationBehavior(.disabled)
        ToolbarItem(id: "toggleInspector") {
            Toggle("Inspector", systemImage: "sidebar.trailing", isOn: $inspectorShown)
                .help(inspectorShown ? "Hide Inspector" : "Show Inspector")
        }
        .customizationBehavior(.disabled)
    }
}

/// Zoom out | the scale, with its menu | zoom in, as one capsule. The scale keeps the widest
/// label's width, as a pop-up keeps its widest item's, so the capsule doesn't move as it changes.
private struct ZoomControl: View {
    let app: AppModel
    let project: ProjectModel

    var body: some View {
        let pdf = project.pdf
        ControlGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { pdf.zoom(in: false) }
                .help("Zoom Out")
                .disabled(!pdf.canZoomOut)
            Menu {
                // The menu bar's items carry the shortcuts.
                ForEach([MenuCommand.viewZoomIn, .viewZoomOut], id: \.self) { command in
                    Button(command.title) { app.perform(command, on: project) }
                        .disabled(!app.isEnabled(command, on: project))
                }
                Divider()
                ScaleMenuItems(pdf: pdf)
            } label: {
                ZStack {
                    Text(pdf.widestZoomLabel).hidden()
                    Text(pdf.zoomLabel)
                }
                .monospacedDigit()
            }
            .help("Scale")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { pdf.zoom(in: true) }
                .help("Zoom In")
                .disabled(!pdf.canZoomIn)
        } label: {
            Label("Zoom", systemImage: "plus.magnifyingglass")
        }
        .disabled(!project.hasPDF)
    }
}

/// Compile as its word, and Stop with a spinner in Compile's width.
private struct CompileButton: View {
    let app: AppModel
    let project: ProjectModel

    var body: some View {
        let compiling = project.compiling
        let command = compiling ? MenuCommand.compileStop : .compileRun
        Button { app.perform(command, on: project) } label: {
            ZStack {
                Text(MenuCommand.compileRun.title)
                    .opacity(compiling ? 0 : 1)
                // The button stays a button to VoiceOver; the status bar says Compiling.
                Label {
                    Text(MenuCommand.compileStop.title)
                } icon: {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                .labelStyle(.titleAndIcon)
                .opacity(compiling ? 1 : 0)
            }
        }
        .buttonStyle(.glassProminent)
        .help(command.title)
        .accessibilityLabel(command.title)
        .disabled(!compiling && !app.isEnabled(.compileRun, on: project))
    }
}
