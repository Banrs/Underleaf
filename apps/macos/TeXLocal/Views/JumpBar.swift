import PDFKit
import SwiftUI

/// The editor's jump bar, as Xcode's: the open file's path and the headings around the caret, each a menu of what sits
/// beside it, and at its end the file's issues to step through. It fills the row the navigator chooser sits in.
struct EditorJumpBar: View {
    let project: ProjectModel

    var body: some View {
        JumpBarRow {
            if let path = project.openPath {
                let nodes = project.tree.nodes
                JumpMenu(project.name, symbol: "folder") { TreeMenu(nodes: nodes, project: project) }
                ForEach(Array(path.split(separator: "/").indices), id: \.self) { depth in
                    let prefix = path.split(separator: "/").prefix(depth + 1).joined(separator: "/")
                    if let node = project.tree.node(at: prefix) {
                        let siblings = depth == 0 ? nodes : project.tree.node(at: prefix.parentFolder)?.children ?? []
                        JumpChevron()
                        JumpMenu(node.name, symbol: node.symbol) { TreeMenu(nodes: siblings, project: project) }
                            .layoutPriority(node.isDirectory ? 0 : 2)
                    }
                }
                ForEach(headings, id: \.node.index) { step in
                    JumpChevron()
                    JumpMenu(step.node.heading.title, symbol: "list.bullet.indent") {
                        ForEach(step.siblings, id: \.index) { node in
                            Button(node.heading.title) { project.reveal(node.heading) }
                        }
                    }
                    .layoutPriority(1)
                }
            }
        } trailing: {
            if let path = project.openPath, project.listed.contains(where: { $0.file == path }) {
                IssueStepper(project: project, path: path)
            }
        }
    }

    /// The headings from the outline's top down to the caret's, each with the headings at its level.
    private var headings: [(node: OutlineNode, siblings: [OutlineNode])] {
        func path(_ nodes: [OutlineNode], to index: Int) -> [(node: OutlineNode, siblings: [OutlineNode])]? {
            for node in nodes {
                if node.index == index { return [(node, nodes)] }
                if let below = path(node.children ?? [], to: index) { return [(node, nodes)] + below }
            }
            return nil
        }
        return project.currentHeading.flatMap { path(project.outlineTree, to: $0) } ?? []
    }
}

/// The PDF's jump bar: its name, then the sections of its own outline around the page shown, each a menu of the sections
/// beside it.
struct PDFJumpBar: View {
    let project: ProjectModel
    let pdf: PDFController

    var body: some View {
        JumpBarRow {
            if pdf.pageCount > 0 {
                JumpMenu(project.buildPDF?.lastPathComponent ?? "PDF", symbol: "richtext.page") {}
                    .layoutPriority(2)
                ForEach(sections, id: \.item) { step in
                    JumpChevron()
                    JumpMenu(step.item.label ?? "", symbol: "list.bullet.indent") {
                        ForEach(step.siblings, id: \.self) { item in
                            Button(item.label ?? "") { if let destination = item.destination { pdf.view.go(to: destination) } }
                        }
                    }
                }
            }
        } trailing: {}
    }

    /// The outline's sections from the top down to the last one starting at or before the page shown.
    private var sections: [(item: PDFOutline, siblings: [PDFOutline])] {
        guard let document = pdf.view.document, let root = document.outlineRoot else { return [] }
        let shown = pdf.page - 1
        var steps: [(item: PDFOutline, siblings: [PDFOutline])] = []
        var level = root
        while level.numberOfChildren > 0 {
            let children = (0..<level.numberOfChildren).compactMap { level.child(at: $0) }
            let page = { (item: PDFOutline) in item.destination?.page.map { document.index(for: $0) } ?? .max }
            guard let item = children.last(where: { page($0) <= shown }) else { break }
            steps.append((item, children))
            level = item
        }
        return steps
    }
}

/// Components keep their full width by priority, the file's first and its folders' last, as Xcode shortens a jump bar.
private struct JumpBarRow<Path: View, Trailing: View>: View {
    @ViewBuilder let path: Path
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            path
            Spacer(minLength: 8)
            trailing
        }
        .buttonStyle(.borderless)
        .lineLimit(1)
        .frame(height: 28)
        .padding(.horizontal, 8)
        .padding(.bottom, 5)
    }
}

private struct JumpMenu<Items: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let items: Items

    init(_ title: String, symbol: String, @ViewBuilder items: () -> Items) {
        (self.title, self.symbol, self.items) = (title, symbol, items())
    }

    var body: some View {
        Menu { items } label: { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help(title)
    }
}

private struct JumpChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
            .fixedSize()
            .layoutPriority(3)
            .accessibilityHidden(true)
    }
}

private struct TreeMenu: View {
    let nodes: [TreeNode]
    let project: ProjectModel

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                Menu { TreeMenu(nodes: children, project: project) } label: { Label(node.name, systemImage: node.symbol) }
            } else {
                Button { Task { await project.open(node.path, jump: true) } } label: { Label(node.name, systemImage: node.symbol) }
            }
        }
    }
}

/// Xcode's issue stepper: previous, the file's issues as a menu, next.
private struct IssueStepper: View {
    let project: ProjectModel
    let path: String

    var body: some View {
        let issues = project.listed.enumerated().filter { $0.element.file == path }
        HStack(spacing: 0) {
            Button("Previous Issue", systemImage: "chevron.backward") { project.goToIssue(next: false) }
            Menu {
                ForEach(issues, id: \.offset) { place, item in
                    Button(item.message.text, systemImage: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill") {
                        project.chooseIssue(place, focus: true)
                    }
                }
            } label: {
                Image(systemName: issues.contains { $0.element.isError } ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityLabel("Issues")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Button("Next Issue", systemImage: "chevron.forward") { project.goToIssue(next: true) }
        }
        .labelStyle(.iconOnly)
        .imageScale(.small)
    }
}
