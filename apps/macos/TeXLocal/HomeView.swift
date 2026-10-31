import AppKit
import QuickLookThumbnailing
import SwiftUI

final class HomeWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, AppWindow {
    private static var kept: [HomeWindowController] = []
    let model: WindowModel

    init(app: AppModel) {
        model = WindowModel(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        model.controller = self
        Self.kept.append(self)
        let home = NSHostingController(rootView: HomeView()
            .frame(minWidth: ColumnMetrics.contentMinimum.width, minHeight: ColumnMetrics.contentMinimum.height)
            .environment(app)
            .environment(model))
        home.sceneBridgingOptions = [.title, .toolbars]
        home.view.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
        let modals = NSHostingView(rootView: WindowModals(window: model, project: nil))
        modals.sizingOptions = []
        home.view.addSubview(modals)
        window.contentViewController = home
        window.center()
        window.setFrameAutosaveName("Projects")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { window?.undoManager }
    func show() { showWindow(nil) }
    func performPDF(_ action: PDFAction) {}
    func revealSidebar() {}

    func focusSearch() { window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first?.beginSearchInteraction() }

    @objc func performFindPanelAction(_ sender: Any?) { focusSearch() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(performFindPanelAction(_:)) || NSTextFinder.Action(rawValue: item.tag) == .showFindInterface
    }

    func windowDidBecomeKey(_ notification: Notification) { model.isKey = true }
    func windowDidResignKey(_ notification: Notification) { model.isKey = false }

    func windowWillClose(_ notification: Notification) {
        model.isKey = false
        model.windowClosed()
        Self.kept.removeAll { $0 === self }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @State private var selection: ProjectInfo.ID?
    @State private var rename = InPlaceRename<ProjectInfo.ID>()
    @FocusState private var listFocused: Bool
    @State private var query = ""
    @State private var slowLoads: [String] = []
    @State private var slowImports: [URL] = []

    var body: some View {
        Group { if let problem = app.libraryProblem { unavailable(problem) } else { list } }
        .fileDrop(accepts: { app.libraryProblem == nil && AppModel.canOpen($0) }) { urls in Task { await window.open(urls) } }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open", systemImage: "folder") { window.openingProject = true }
                    .help("Open a folder, .tex file or .zip as a project")
                    .disabled(app.libraryProblem != nil)
                Button("New Project", systemImage: "plus") { window.newProject() }
                    .help("Name a project and choose its template")
                    .disabled(app.libraryProblem != nil)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Projects")
        .task(id: loading) {
            if !copied { do { try await Task.sleep(for: .milliseconds(300)) } catch { return } }
            slowLoads = loading
        }
        .task(id: window.importing) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            slowImports = window.importing
        }
    }

    private var list: some View {
        List(selection: $selection) {
            VStack(alignment: .leading, spacing: 8) {
                Text("New").font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
                templates.padding(.horizontal, -TemplateButtonStyle.edge)
            }
            .selectionDisabled()
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("New")
            Section {
                ForEach(copying, id: \.self) { url in
                    ProjectLabel(detail: Text("Opening…"), progress: "Opening") { Text(url.lastPathComponent).font(.headline) }
                }
                ForEach(shown) { project in
                    ProjectRow(project: project, working: loading.contains(project.id) && (slowLoads.contains(project.id) || copied),
                               rename: rename, ended: { listFocused = true }) { commitRename(project) }
                }
                if app.projectsLoaded, shown.isEmpty { noProjects.frame(maxWidth: .infinity).selectionDisabled() }
            } header: { Text("All Projects") }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ProjectInfo.ID.self) { ids in
            if let project = app.projects.first(where: { ids.contains($0.id) }) {
                Button("Open") { Task { await window.open(project.id) } }
                Divider()
                if project.opened {
                    Button { actions(project).showInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
                        .disabled(project.missing)
                    Divider()
                    Button { Task { await window.forget(project) } } label: { Label("Remove from List", systemImage: "minus.circle") }
                        .disabled(app.window(showing: project.id) != nil)
                } else {
                    Button { Task { if let copy = await window.duplicate(project) { selection = copy } } } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    ItemMenuItems(actions: actions(project))
                }
            }
        } primaryAction: { ids in if let id = ids.first { Task { await window.open(id) } } }
        .onKeyPress(.return) {
            guard rename.id == nil, let id = selection else { return .ignored }
            Task { await window.open(id) }
            return .handled
        }
        .focused($listFocused)
        .offersActions(for: listFocused && rename.id == nil ? selection : nil) { id in shown.first { $0.id == id }.map(actions) }
        .onChange(of: app.projectsLoaded, initial: true) { if selection == nil { selection = app.projects.first?.id } }
    }

    private func actions(_ project: ProjectInfo) -> ItemActions {
        let changes = app.canChange(project)
        return ItemActions(rename: changes ? { rename.begin(project.id, name: project.name) } : nil,
                           showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([project.folder]) },
                           moveToTrash: changes ? { Task { await window.delete(project) } } : nil)
    }

    private var templates: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: TemplateCard.width, maximum: TemplateCard.width), spacing: 4, alignment: .top)],
                  alignment: .leading, spacing: 4) {
            ForEach(ProjectTemplate.allCases) { template in
                Button { window.newProject(template) } label: { TemplateCard(template: template) }
                .buttonStyle(TemplateButtonStyle())
                .help("Start a project from the \(template.title) template")
            }
        }
    }

    private func commitRename(_ project: ProjectInfo) {
        guard let name = rename.end(project.id, from: project.name) else { return }
        Task { await window.rename(project, to: name) }
    }

    private var loading: [String] {
        app.windows.compactMap(\.project).filter { !$0.initialLoadComplete && !$0.closed }.map(\.id)
    }

    private var copying: [URL] { query.isEmpty ? slowImports.filter(window.importing.contains) : [] }

    private var copied: Bool { slowImports.contains { !window.importing.contains($0) } }

    private var shown: [ProjectInfo] {
        query.isEmpty ? app.projects : app.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func unavailable(_ problem: AppAlert) -> some View {
        ContentUnavailableView {
            Label(problem.title, systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(problem.message)
        } actions: {
            Button("Try Again") { Task { await app.retryLibrary() } }
        }
    }

    @ViewBuilder private var noProjects: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("No Projects Yet", systemImage: "text.document")
            } description: {
                Text("Choose a template above, or open or drop a folder, .tex file or .zip.")
            } actions: {
                Button("Open…") { window.openingProject = true }
            }
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectInfo
    let working: Bool
    let rename: InPlaceRename<ProjectInfo.ID>
    let ended, commit: () -> Void

    var body: some View {
        ProjectLabel(detail: detail, symbol: project.opened ? "folder" : "text.document", pdf: project.pdf.map { ($0, project.mtime) },
                     dimmed: project.missing, progress: working ? "Opening" : nil) {
            if rename.id == project.id {
                RenameField(text: Bindable(rename).name, ended: ended, commit: commit) { rename.cancel() }
            } else {
                Text(project.name).font(.headline)
            }
        }
    }

    private var detail: Text {
        guard project.opened else {
            return Text("\(Text(project.mainFile)) · \(Text(.currentDate, format: .reference(to: project.modified)))")
        }
        let path = (project.path as NSString).abbreviatingWithTildeInPath
        return project.missing ? Text("\(path) · Not Found") : Text(path)
    }
}

private struct ProjectLabel<Name: View>: View {
    let detail: Text
    var symbol = "text.document"
    var pdf: (path: String, built: UInt64)?
    var dimmed = false
    let progress: String?
    @ViewBuilder let name: Name
    @Environment(\.displayScale) private var scale
    @State private var page: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let page {
                    let paper = RoundedRectangle(cornerRadius: 2)
                    Image(nsImage: page).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(paper)
                        .overlay { paper.strokeBorder(.separator) }
                } else {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(dimmed ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                }
            }
            .frame(width: thumbnail.width, height: thumbnail.height)
            .accessibilityHidden(true)
            .task(id: pdf.map { "\($0.built) \($0.path)" }) {
                guard let pdf else { return page = nil }
                let request = QLThumbnailGenerator.Request(fileAt: URL(filePath: pdf.path), size: thumbnail, scale: scale,
                                                           representationTypes: .thumbnail)
                page = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            }
            VStack(alignment: .leading, spacing: 2) {
                name.foregroundStyle(dimmed ? HierarchicalShapeStyle.tertiary : .primary)
                detail.font(.subheadline).foregroundStyle(dimmed ? HierarchicalShapeStyle.tertiary : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let progress {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(progress)
            }
        }
    }
}

private let thumbnail = CGSize(width: 32, height: 40)

private struct TemplateCard: View {
    let template: ProjectTemplate
    private static let page = CGSize(width: 120, height: 120 * 11 / 8.5)
    static let width = page.width + 2 * TemplateButtonStyle.edge
    private static let corner: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let paper = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(spacing: 8) {
            PagePreview(template: template)
                .frame(width: Self.page.width, height: Self.page.height)
                .background(Color.white.opacity(colorScheme == .dark ? 0.88 : 1), in: paper)
                .overlay { paper.strokeBorder(.separator) }
                .environment(\.colorScheme, .light)
                .accessibilityHidden(true)
            Text(template.title)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TemplateButtonStyle: ButtonStyle {
    static let edge: CGFloat = 10
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .padding(Self.edge)
            .background {
                if configuration.isPressed { shape.fill(.fill.secondary) } else if hovered { shape.fill(.fill.tertiary) }
            }
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .onHover { hovered = $0 }
    }
}

struct NewProjectSheet: View {
    @Environment(WindowModel.self) private var window
    @State var draft: NewProjectDraft
    @FocusState private var nameFocused: Bool

    private var trimmed: String { draft.name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DialogSheet(title: "New Project", message: "Saved in \(Core.libraryPath).",
                    action: "Create", enabled: !trimmed.isEmpty) {
            try await window.create(name: trimmed, template: draft.template)
        } fields: {
            DialogField(label: "Name", text: $draft.name, prompt: "Required", focus: $nameFocused)
            Picker("Template", selection: $draft.template) { ForEach(ProjectTemplate.allCases) { Text($0.title).tag($0) } }
        }
        .defaultFocus($nameFocused, true)
    }
}
