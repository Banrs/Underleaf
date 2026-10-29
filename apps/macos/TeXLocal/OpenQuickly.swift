import AppKit
import SwiftUI

final class OpenQuickly: NSPanel {
    private static weak var shown: OpenQuickly?

    static func show(for project: ProjectModel) {
        if let shown { return shown.makeKey() }
        guard let window = NSApp.mainWindow else { return }
        let panel = OpenQuickly(project: project)
        let area = window.convertToScreen(window.contentLayoutRect), wide = min(width, area.width - 40)
        panel.setFrame(NSRect(x: area.midX - wide / 2, y: area.maxY - 40 - fieldHeight, width: wide, height: fieldHeight), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKey()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.field.focus()
        shown = panel
        panel.search("")
    }

    static let width: CGFloat = 600, fieldHeight: CGFloat = 48, rowHeight: CGFloat = 38, shownRows = 10

    private let project: ProjectModel
    private let rows = ChoiceRows<QuickOpenItem> { [$0.title, $0.detail] }
    private let field = FieldHandle()
    private var searching: Task<Void, Never>?

    private init(project: ProjectModel) {
        self.project = project
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: QuickOpenView(field: field, rows: rows, tree: project.tree, search: { [unowned self] in search($0) },
                                                         open: { [unowned self] in open($0) }, close: { [unowned self] in close() }))
        host.sizingOptions = []
        contentView = host
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        if parent != nil { close() }
    }

    override func close() {
        searching?.cancel()
        parent?.removeChildWindow(self)
        super.close()
    }

    private func search(_ query: String) {
        searching?.cancel()
        searching = Task { [project] in
            guard let items = try? await project.session.call(QuickOpen(query: query)), !Task.isCancelled else { return }
            rows.items = items
            var frame = self.frame
            let height = Self.fieldHeight + (items.isEmpty ? 0 : CGFloat(min(items.count, Self.shownRows)) * Self.rowHeight
                + 2 * CompletionRowsView.margin)
            (frame.origin.y, frame.size.height) = (frame.maxY - height, height)
            setFrame(frame, display: true)
        }
    }

    private func open(_ row: Int) {
        guard rows.items.indices.contains(row) else { return }
        let item = rows.items[row]
        close()
        Task { [project] in await project.open(item.path, line: item.line, atTop: item.kind == .heading, jump: true) }
    }
}

private struct QuickOpenView: View {
    let field: FieldHandle
    let rows: ChoiceRows<QuickOpenItem>
    let tree: FileTree
    let search: (String) -> Void
    let open: (Int) -> Void
    let close: @MainActor () -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                SearchField(text: $query, prompt: String(localized: "Open Quickly"), large: true, handle: field,
                            step: { _ in open(rows.selection) }, move: rows.move, close: close)
                    .onChange(of: query) { search(query) }
            }
            .padding(.horizontal, 16)
            .frame(height: OpenQuickly.fieldHeight)
            if !rows.items.isEmpty {
                Divider()
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 0) { ForEach(rows.items.indices, id: \.self, content: row) }
                    }
                    .scrollIndicators(.never)
                    .padding(.vertical, CompletionRowsView.margin)
                    .onChange(of: rows.revealed) { scroller.scrollTo(rows.selection) }
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open Quickly")
    }

    private func row(_ index: Int) -> some View {
        let item = rows.items[index], chosen = index == rows.selection
        let symbol = switch item.kind {
        case .heading: "list.bullet.indent"
        case .label: "tag"
        case .file: tree.node(at: item.path)?.symbol ?? "document"
        }
        return HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(Color(nsColor: chosen ? .alternateSelectedControlTextColor : .labelColor))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CompletionRowsView.textInset)
        .frame(height: OpenQuickly.rowHeight)
        .background(chosen ? Color(nsColor: .controlAccentColor) : .clear, in: .rect(cornerRadius: 8))
        .padding(.horizontal, CompletionRowsView.margin)
        .contentShape(.rect)
        .onTapGesture { open(index) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .id(index)
    }
}
