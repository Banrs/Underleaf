import SwiftUI

struct BuildPanel: View {
    let project: ProjectModel

    var body: some View {
        Group {
            if project.panel.tab == .texpresso, project.texpresso.log.isEmpty {
                ContentUnavailableView(project.texpresso.title, systemImage: "bolt", description: Text(
                    project.texpresso.active ? "The PDF pane shows Live Preview." : "Its log shows here while it runs."))
            } else if project.panel.tab == .texpresso {
                LogPane(text: project.texpresso.log, filter: project.panel.logFilter, title: PanelTab.texpresso.title)
            } else if project.buildLog.isEmpty {
                ContentUnavailableView("No Build Log", systemImage: "text.page", description: Text("Compile to see the log here."))
            } else {
                LogPane(text: project.buildLog, filter: project.panel.logFilter, title: PanelTab.log.title)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.textSurface)
        .safeAreaInset(edge: .bottom, spacing: 0) { BuildPanelBar(project: project) }
    }
}

private struct BuildPanelBar: View {
    let project: ProjectModel

    var body: some View {
        @Bindable var panel = project.panel
        HStack {
            Picker("Show", selection: $panel.tab) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Text(tab.title).selectionDisabled(tab == .texpresso && !project.texpresso.used)
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .labelsHidden()
            .fixedSize()
            .layoutPriority(1)
            Spacer(minLength: 0)
            let text = panel.tab == .texpresso ? project.texpresso.log : project.buildLog
            Button("Copy Log", systemImage: "document.on.document") { NSPasteboard.general.replaceContents(with: text) }
                .help("Copy the whole log")
                .disabled(text.isEmpty)
            SearchField(text: $panel.logFilter, prompt: String(localized: "Filter"), symbol: SearchField.filterSymbol)
                .controlSize(.regular)
                .frame(maxWidth: 180)
        }
        .buttonStyle(.accessoryBar)
        .labelStyle(.iconOnly)
        .barRow()
        .background(.textSurface)
        .barEdge()
    }
}

struct LogTextView: NSViewRepresentable {
    let text: String
    var title = "Build Log"
    var bottomInset: CGFloat = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.autohidesScrollers = true
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
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets.bottom = bottomInset
            scroll.scrollerInsets.bottom = bottomInset
            if atEnd { view.scrollToEndOfDocument(nil) }
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
            view.scrollToEndOfDocument(nil)
        } else {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
