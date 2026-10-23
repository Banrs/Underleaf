import SwiftUI
import UIKit

/// Issues, the build's log and Live Preview's, with their controls along the top: a window's bottom edge can be off screen.
struct BuildPanel: View {
    let project: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            BuildPanelBar(project: project)
            Divider()
            BuildPanelPage(project: project)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

/// A tap goes to the issue; a long press offers it to copy.
struct IssueList: View {
    let items: [(offset: Int, element: LogItem)]
    let project: ProjectModel

    var body: some View {
        List(items, id: \.offset) { row in
            let item = row.element
            IssueRow(item: item, place: row.offset, project: project)
                .listRowBackground(row.offset == project.chosenIssue ? Color.accentColor.opacity(0.15) : nil)
                .contextMenu {
                    if item.file != nil {
                        Button(item.line == nil ? "Open File" : "Go to Line", systemImage: "arrow.right") {
                            project.chooseIssue(row.offset, focus: true)
                        }
                    }
                    Button("Copy", systemImage: "document.on.document") { UIPasteboard.general.string = item.message }
                }
        }
        .listStyle(.plain)
    }
}

private struct BuildPanelBar: View {
    let project: ProjectModel

    var body: some View {
        // One row where it fits, else the tabs above their controls.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                tabs
                Spacer(minLength: 0)
                controls
            }
            VStack(alignment: .leading, spacing: 8) {
                tabs
                HStack(spacing: 12) { controls }
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private var tabs: some View {
        @Bindable var panel = project.panel
        return Picker("Show", selection: $panel.tab) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab).selectionDisabled(tab == .texpresso && !project.texpresso.used)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var controls: some View {
        @Bindable var panel = project.panel
        if panel.tab == .issues {
            Toggle(isOn: $panel.showsWarnings) { Label("Warnings", systemImage: "exclamationmark.triangle") }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .disabled(project.warningCount == 0 && project.result?.badBoxes.isEmpty != false)
            filter($panel.issueFilter)
        } else {
            let text = panel.tab == .texpresso ? project.texpresso.log : project.result?.log ?? ""
            Button("Copy Log", systemImage: "document.on.document") { UIPasteboard.general.string = text }
                .labelStyle(.iconOnly)
                .disabled(text.isEmpty)
            filter($panel.logFilter)
        }
    }

    private func filter(_ text: Binding<String>) -> some View {
        TextField("Filter", text: text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(minWidth: 120, maxWidth: 200)
    }
}

/// A read-only text view: SwiftUI's Text lays a megabyte log out whole on every change. It follows the end as the log grows,
/// unless it has been scrolled up.
struct LogTextView: UIViewRepresentable {
    let text: String
    var title = "Build Log"
    var bottomInset: CGFloat = 0

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isFindInteractionEnabled = true
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.alwaysBounceVertical = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.accessibilityLabel = title
        view.contentInset.bottom = bottomInset
        guard view.text != text else { return }
        let atEnd = view.contentOffset.y + view.bounds.height >= view.contentSize.height - 1
        view.text = text
        if atEnd { view.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0)) }
    }
}
