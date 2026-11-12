import SwiftUI

struct BuildPanel: View {
    let project: ProjectModel

    var body: some View {
        let live = project.panel.tab == .texpresso
        let text = live ? project.liveLog : project.buildLog
        Group {
            if !text.isEmpty {
                LogPane(text: text, filter: project.panel.logFilter, hiddenKinds: project.panel.hiddenLogKinds,
                        title: project.panel.tab.title)
                    .id(project.panel.tab)
            } else if live {
                ContentUnavailableView(project.liveTitle, systemImage: "bolt", description: Text(
                    project.liveActive ? "The PDF pane shows Live Preview." : "Its log shows here while it runs."))
            } else {
                ContentUnavailableView("No Build Log", systemImage: "text.page", description: Text("Compile to see the log here."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.textSurface)
        .safeAreaInset(edge: .bottom, spacing: 0) { BuildPanelBar(project: project) }
    }
}

/// The log's controls, which float over its bottom edge on glass so the log scrolls beneath them.
struct BuildPanelBar: View {
    let project: ProjectModel

    var body: some View {
        @Bindable var panel = project.panel
        HStack(spacing: 6) {
            // Neither a menu nor a menu picker takes the glass button style, so the capsule is drawn here at a regular
            // control's height.
            Picker("Show", selection: $panel.tab) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Text(tab.title).selectionDisabled(tab == .texpresso && !project.livePreviewUsed)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .buttonStyle(.borderless)
            .controlSize(.small)
            // Sets the title's first stem over the log text's, 17.5 pt into the pane at 13 pt, as Xcode's console lines up its own.
            .padding(.horizontal, 6.5)
            .frame(height: 24)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
            Spacer(minLength: 0)
            let text = panel.tab == .texpresso ? project.liveLog : project.buildLog
            Button { NSPasteboard.general.replaceContents(with: text) } label: {
                // A glass button sets its label at the control's 13 pt, which fills the circle beside the bar's 11 pt symbols.
                Label("Copy Log", systemImage: "document.on.document").font(.subheadline)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .labelStyle(.iconOnly)
            .help("Copy the whole log")
            .disabled(text.isEmpty)
            FilterField(text: $panel.logFilter, help: String(localized: "Show lines with matching text"),
                        options: LogKind.allCases.map { ($0.title, $panel.hiddenLogKinds[lacks: $0]) },
                        hasActiveOptions: !panel.hiddenLogKinds.isEmpty) {}
                .frame(maxWidth: 182)
        }
        .font(.subheadline)
        .padding(7)
    }
}
