import AppKit
import SwiftUI

/// Xcode's Open Quickly: a field at the window's top centre over the core's best matches among the project's files, headings
/// and labels (`session_quick_open`). The arrows choose, Return opens, Escape or a click elsewhere closes. A key panel of
/// its own, whose glass draws as the completion list's.
final class OpenQuickly: NSPanel, NSTextFieldDelegate {
    private static weak var shown: OpenQuickly?

    static func show(for project: ProjectModel) {
        if let shown { return shown.makeKey() }
        guard let window = NSApp.mainWindow else { return }
        let panel = OpenQuickly(project: project)
        let area = window.convertToScreen(window.contentLayoutRect), wide = min(width, area.width - 40)
        panel.setFrame(NSRect(x: area.midX - wide / 2, y: area.maxY - 40 - fieldHeight, width: wide, height: fieldHeight), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKey()
        panel.makeFirstResponder(panel.field)
        shown = panel
        panel.search()
    }

    static let width: CGFloat = 600, fieldHeight: CGFloat = 48, rowHeight: CGFloat = 38, shownRows = 10

    private let project: ProjectModel
    private let rows = ChoiceRows<QuickOpenItem> { [$0.title, $0.detail] }
    private let field = NSTextField()
    private var searching: Task<Void, Never>?

    private init(project: ProjectModel) {
        self.project = project
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        field.placeholderString = String(localized: "Open Quickly")
        // For VoiceOver, as the placeholder goes once there's text.
        field.setAccessibilityLabel(field.placeholderString)
        field.font = .systemFont(ofSize: 20)
        (field.isBezeled, field.drawsBackground, field.focusRingType) = (false, false, .none)
        field.delegate = self
        let host = NSHostingView(rootView: QuickOpenView(field: field, rows: rows, tree: project.tree) { [unowned self] in open($0) })
        host.sizingOptions = []
        contentView = host
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        // Closing orders it out, which resigns again.
        if parent != nil { close() }
    }

    override func close() {
        parent?.removeChildWindow(self)
        super.close()
    }

    func controlTextDidChange(_ notification: Notification) { search() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // The input method's Return and Escape first.
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): rows.move(-1)
        case #selector(NSResponder.moveDown(_:)): rows.move(1)
        case #selector(NSResponder.insertNewline(_:)): open(rows.selection)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func search() {
        guard let session = project.session else { return }
        let query = field.stringValue
        searching?.cancel()
        searching = Task {
            guard let items = try? await project.core.call("session_quick_open", ["session": session, "query": query],
                                                           as: [QuickOpenItem].self), !Task.isCancelled else { return }
            rows.items = items
            // Down from the field, the top staying where it is.
            var frame = self.frame
            let height = Self.fieldHeight + (items.isEmpty ? 0 : CGFloat(min(items.count, Self.shownRows)) * Self.rowHeight
                + 2 * CompletionRowsView.margin)
            (frame.origin.y, frame.size.height) = (frame.maxY - height, height)
            setFrame(frame, display: true)
        }
    }

    /// As a click in the sidebar or the outline opens it, at its line.
    private func open(_ row: Int) {
        guard rows.items.indices.contains(row) else { return }
        let item = rows.items[row]
        close()
        Task { [project] in await project.open(item.path, line: item.line, atTop: item.kind == "heading", jump: true) }
    }
}

nonisolated struct QuickOpenItem: Decodable {
    /// `file`, `heading` or `label`.
    let kind, title, detail, path: String
    let line: Int?
}

/// The completion list's look at the field's size: rows 5 pt in, the chosen one in the accent with white text.
private struct QuickOpenView: View {
    let field: NSTextField
    let rows: ChoiceRows<QuickOpenItem>
    let tree: FileTree
    let open: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                Field(field: field)
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
        case "heading": "list.bullet.indent"
        case "label": "tag"
        default: tree.node(at: item.path)?.symbol ?? "document"
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

/// The panel's own field, whose delegate takes the arrows, Return and Escape.
private struct Field: NSViewRepresentable {
    let field: NSTextField

    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ view: NSTextField, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }
}
