import SwiftUI

struct BuildPanel: View {
    let project: ProjectModel

    var body: some View {
        Group {
            if project.panel.tab == .texpresso, project.texpresso.log.isEmpty {
                ContentUnavailableView(project.texpresso.title, systemImage: "bolt", description: Text(
                    project.texpresso.active ? "The PDF pane shows Live Preview." : "Its log shows here while it runs."))
            } else if project.panel.tab == .texpresso {
                LogPane(text: project.texpresso.log, filter: project.panel.logFilter, hiddenKinds: project.panel.hiddenLogKinds,
                        title: PanelTab.texpresso.title)
            } else if project.buildLog.isEmpty {
                ContentUnavailableView("No Build Log", systemImage: "text.page", description: Text("Compile to see the log here."))
            } else {
                LogPane(text: project.buildLog, filter: project.panel.logFilter, hiddenKinds: project.panel.hiddenLogKinds,
                        title: PanelTab.log.title)
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
                    Text(tab.title).selectionDisabled(tab == .texpresso && !project.texpresso.used)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
            Spacer(minLength: 0)
            let text = panel.tab == .texpresso ? project.texpresso.log : project.buildLog
            Button("Copy Log", systemImage: "document.on.document") { NSPasteboard.general.replaceContents(with: text) }
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
        .padding(7)
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
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.textContainerInset = NSSize(width: 10, height: 8)
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
                                          weight: .regular)
        return scroll
    }

    final class Coordinator { var shown: String? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        view.setAccessibilityLabel(title)
        if scroll.contentInsets.bottom != bottomInset {
            let atEnd = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1
            scroll.contentInsets.bottom = bottomInset
            scroll.scrollerInsets.bottom = bottomInset
            if atEnd { scrollToEnd(scroll, view) }
        }
        guard context.coordinator.shown != text else { return }
        updateText(in: scroll)
        context.coordinator.shown = text
    }

    private func updateText(in scroll: NSScrollView) {
        let view = scroll.documentView as! NSTextView
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
