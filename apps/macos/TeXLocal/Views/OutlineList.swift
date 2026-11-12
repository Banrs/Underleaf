import SwiftUI

struct OutlineList: View {
    let project: ProjectModel
    @State private var chosen: Int?

    var body: some View {
        let outline = project.outline
        let current = project.currentHeading
        let filter = project.navigator.outlineFilter
        let nodes = filtered(project.outlineTree, \.children, by: filter) { $0.heading.title }
        let selection = Binding<Int?>(get: { chosen ?? current }, set: { id in
            guard let id, id != current, outline.indices.contains(id) else { return }
            chosen = id
            project.reveal(outline[id])
        })
        ScrollViewReader { proxy in
            List(selection: selection) {
                TreeRows(nodes: nodes, children: \.children, isExpanded: { node in
                    filter.isEmpty ? disclosure(\.foldedHeadings, of: project, key: node.foldKey, inverted: true,
                                                subtree: node.descendants.map(\.foldKey)) : .constant(true)
                }) { node in
                    HeadingRow(node: node).tag(node.id)
                        .simultaneousGesture(TapGesture().onEnded {
                            // A double-click's second click is the list's primary action, which opens the heading in the source.
                            guard NSApp.currentEvent?.clickCount ?? 1 < 2, node.id == current || node.id == chosen else { return }
                            chosen = node.id == current ? nil : node.id
                            project.reveal(node.heading)
                        })
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Outline")
            .overlay {
                if !filter.isEmpty, nodes.isEmpty, !outline.isEmpty {
                    NoFilterResults()
                } else if outline.isEmpty {
                    ContentUnavailableView("No Sections", systemImage: "list.bullet.indent")
                }
            }
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { ids in
                guard let id = ids.first, outline.indices.contains(id) else { return }
                let heading = outline[id]
                Task { await project.open(heading.file, line: heading.line, atTop: true, focus: true, jump: true) }
            }
            .onChange(of: current, initial: true) { _, id in
                chosen = nil
                guard let id else { return }
                Task { proxy.scrollTo(id) }
            }
        }
    }
}

private struct HeadingRow: View {
    let node: OutlineNode

    var body: some View {
        let heading = node.heading
        Text(heading.title)
            .help(heading.title)
            .foregroundStyle(heading.untitled ? .secondary : .primary)
            .lineLimit(1)
            .accessibilityValue(heading.level)
            // A row with no icon would otherwise start its title against the disclosure chevron.
            .padding(.leading, 6)
            .id(node.id)
    }
}
