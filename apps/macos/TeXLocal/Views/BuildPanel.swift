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

struct LogTextView: NSViewRepresentable {
    let text: String
    let title: String
    let bottomInset: CGFloat
    let font: NSFont

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        // With the container's own padding, text starts 16 pt in, as in Xcode's console.
        view.textContainerInset = NSSize(width: 11, height: 8)
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        view.setAccessibilityLabel(title)
        if view.font != font {
            let style = SourceTextView.rowStyle(for: font)
            view.font = font
            view.defaultParagraphStyle = style
            view.textStorage?.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        }
        if scroll.contentInsets.bottom != bottomInset {
            let atEnd = scroll.documentVisibleRect.maxY >= view.bounds.maxY - 1
            scroll.contentInsets.bottom = bottomInset
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
        let added = previousLength > 0 && text.utf16.starts(with: shown.utf16)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: view.defaultParagraphStyle ?? .default,
                                                         .foregroundColor: NSColor.textColor]
        view.textStorage?.replaceCharacters(in: added ? .caret(previousLength) : NSRange(location: 0, length: previousLength),
                                            with: NSAttributedString(string: added ? new.substring(from: previousLength) : text, attributes: attributes))
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
        Task { [weak scroll] in
            guard let scroll else { return }
            let clip = scroll.contentView
            var bottom = clip.bounds
            bottom.origin.y = clip.documentRect.maxY
            clip.scroll(to: clip.constrainBoundsRect(bottom).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
