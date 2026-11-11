import SwiftUI

private enum FilterBarMetrics {
    static let controlHeight = NSSearchField().intrinsicContentSize.height
    static let font = Font.system(size: NSFont.systemFontSize(for: .regular))
    static let spacing: CGFloat = 6
    static let inset: CGFloat = 7
}

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

/// The log's controls along its bottom edge.
struct BuildPanelBar: View {
    let project: ProjectModel

    var body: some View {
        @Bindable var panel = project.panel
        HStack(spacing: FilterBarMetrics.spacing) {
            Picker("Show", selection: $panel.tab) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Text(tab.title).selectionDisabled(tab == .texpresso && !project.livePreviewUsed)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: FilterBarMetrics.controlHeight)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
            Spacer(minLength: 0)
            let text = panel.tab == .texpresso ? project.liveLog : project.buildLog
            Button { NSPasteboard.general.replaceContents(with: text) } label: {
                Label("Copy Log", systemImage: "document.on.document").labelStyle(.iconOnly)
                    .frame(width: FilterBarMetrics.controlHeight, height: FilterBarMetrics.controlHeight)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("Copy the whole log")
            .disabled(text.isEmpty)
            FilterField(text: $panel.logFilter, help: String(localized: "Show lines with matching text"),
                        options: LogKind.allCases.map { ($0.title, $panel.hiddenLogKinds[lacks: $0]) },
                        height: FilterBarMetrics.controlHeight, symbolFont: .subheadline,
                        hasActiveOptions: !panel.hiddenLogKinds.isEmpty) {}
                .frame(maxWidth: 182)
        }
        .controlSize(.regular)
        .font(FilterBarMetrics.font)
        .padding(FilterBarMetrics.inset)
    }
}

struct LogTextView: NSViewRepresentable {
    let text: String
    let title: String
    let bottomInset: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.automaticallyAdjustsContentInsets = false
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.textContainerInset = NSSize(width: 10, height: 8)
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                                          weight: .regular)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        view.setAccessibilityLabel(title)
        if scroll.contentInsets.bottom != bottomInset || scroll.contentView.contentInsets.bottom != bottomInset {
            let atEnd = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1
            scroll.contentInsets.bottom = bottomInset
            scroll.contentView.contentInsets.bottom = bottomInset
            scroll.scrollerInsets.bottom = bottomInset
            if atEnd { scrollToEnd(scroll, view) }
        }
        let shown = view.string
        guard shown != text else { return }
        let selections = view.selectedRanges.map(\.rangeValue)
        let origin = scroll.contentView.bounds.origin
        let followsTail = !scroll.isFindBarVisible && selections.allSatisfy { $0.length == 0 }
            && (shown.isEmpty || scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1)
        let previousLength = (shown as NSString).length, new = text as NSString
        if previousLength > 0, text.utf16.starts(with: shown.utf16) {
            view.textStorage?.replaceCharacters(in: .caret(previousLength), with: new.substring(from: previousLength))
        } else {
            view.string = text
        }
        view.didChangeText()
        let length = new.length
        view.selectedRanges = selections.map { range in
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
        if followsTail {
            scrollToEnd(scroll, view)
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func scrollToEnd(_ scroll: NSScrollView, _ view: NSTextView) {
        view.scrollToEndOfDocument(nil)
        // SwiftUI may finish sizing the viewport after this update. Follow its final bottom inset too.
        Task { [weak scroll, weak view] in
            guard let scroll, let view, scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1 else { return }
            let clip = scroll.contentView
            var bottom = clip.bounds
            bottom.origin.y = clip.documentRect.maxY
            clip.scroll(to: clip.constrainBoundsRect(bottom).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
