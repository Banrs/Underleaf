import SwiftUI

/// The window's content: the projects, or the open project's workspace once its first
/// file and outline are ready, so it doesn't animate them in.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    /// Where the project was left, with the window's state: with "Close windows when
    /// quitting an app" on, the next launch shows the projects.
    @SceneStorage("workspace") private var saved: Data?

    var body: some View {
        Group {
            if let project = app.project, project.initialLoadComplete {
                WorkspaceView(project: project)
                    .id(ObjectIdentifier(project))
            } else {
                HomeView()
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .windowModals()
        .onAppear { app.showWindow = { [openWindow] in openWindow(id: "main") } }
        .task { await launch() }
        .onChange(of: app.project?.saved) { _, workspace in
            saved = workspace.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    /// Opens the launch argument's project, or the one the window was left on.
    private func launch() async {
        guard Core.shared.isOpen, app.project == nil else { return }
        await app.refresh()
        let restored = saved.flatMap { try? JSONDecoder().decode(SavedWorkspace.self, from: $0) }
            .flatMap { saved in app.projects.contains { $0.id == saved.project } ? saved : nil }
        if let id = app.takeLaunchProject() ?? restored?.project, app.project == nil, !app.isOpening {
            await app.open(id, restoring: restored)
        }
    }
}

/// Sidebar | source and PDF over the build panel | inspector, under the window's toolbar.
/// Which panes show is the window's (`SceneStorage`); the menus reach them through
/// `WorkspaceActions`.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var project: ProjectModel
    @SceneStorage("sidebar") private var sidebarShown = true
    @SceneStorage("inspector") private var inspectorShown = false
    @SceneStorage("pdf") private var pdfShown = true
    @SceneStorage("outlineFolded") private var outlineFolded = false
    @FocusState private var searchFocused: Bool
    @State private var formatShown = false

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(project: project, outlineFolded: $outlineFolded)
                .searchable(text: $project.searchQuery, placement: .sidebar, prompt: "Search Project")
                .searchFocused($searchFocused)
        } detail: {
            // Not under the bar: AppKit's scroll views inside wouldn't know to inset their ends.
            EditorSplit(app: app, project: project, showPDF: pdfShown, showPanel: project.showLogs)
                .safeAreaBar(edge: .bottom) { StatusBar(project: project, pdfShown: pdfShown) }
                .inspector(isPresented: $inspectorShown) { InspectorView(project: project) }
                .toolbar(id: "workspace") {
                    WorkspaceToolbar(app: app, project: project, pdfShown: $pdfShown,
                                     inspectorShown: $inspectorShown.animation(motion), formatShown: $formatShown)
                }
        }
        .navigationTitle(project.openPath?.fileName ?? project.id)
        .navigationSubtitle(project.openPath == nil ? "" : project.id)
        // The proxy icon, for the open file only: a modifier that came and went would make
        // the workspace anew.
        .background {
            if let url = project.openURL { Color.clear.navigationDocument(url) }
        }
        .modifier(WorkspaceModals(project: project))
        // Nil behind Settings or a sheet, which turns the project's menu items off.
        .focusedSceneValue(\.workspace, activeState == .key ? actions : nil)
        // A PDF action, Go to PDF Position or a live preview shows the column.
        .onChange(of: project.pdf.waitsForColumn) { _, waits in if waits { pdfShown = true } }
        .onChange(of: project.livePDF) { _, live in if live { pdfShown = true } }
    }

    private var motion: Animation? { reduceMotion ? nil : .default }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarShown ? .all : .detailOnly }, set: { sidebarShown = $0 != .detailOnly })
    }

    private var actions: WorkspaceActions {
        WorkspaceActions(
            project: project,
            sidebar: $sidebarShown.animation(motion),
            pdf: $pdfShown,
            outlineFolded: $outlineFolded.animation(motion),
            focusSearch: {
                withAnimation(motion) { sidebarShown = true }
                // At once, so typing during the sidebar's animation lands in it.
                searchFocused = true
            })
    }
}

/// The workspace's panes for the menus, from the key window's workspace.
struct WorkspaceActions {
    let project: ProjectModel
    let sidebar: Binding<Bool>
    let pdf: Binding<Bool>
    let outlineFolded: Binding<Bool>
    let focusSearch: () -> Void
}

extension FocusedValues {
    @Entry var workspace: WorkspaceActions?
    /// The chosen item of the list with the keyboard, for File's Rename, Show in Finder
    /// and Move to Trash (`offersActions`).
    @Entry var itemActions: ItemActions?
}
