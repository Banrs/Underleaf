import SwiftUI
import UIKit

/// Issues, the build's log and Live Preview's, with their controls along the top: a window's bottom edge can be off screen.
struct BuildPanel: View {
    let project: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            BuildPanelBar(project: project)
            Divider()
            Group {
                switch project.panel.tab {
                case .issues: issues
                case .log:
                    if let text = project.result?.log, !text.isEmpty {
                        LogPane(text: text, filter: project.panel.logFilter)
                    } else {
                        ContentUnavailableView("No Log", systemImage: "text.page", description: Text("Compile to see the log here."))
                    }
                case .texpresso:
                    if project.texpresso.log.isEmpty {
                        ContentUnavailableView(project.texpresso.title, systemImage: "bolt", description: Text(
                            project.texpresso.active ? "The PDF pane shows Live Preview." : "Its log shows here while it runs."))
                    } else {
                        LogPane(text: project.texpresso.log, filter: project.panel.logFilter, title: "Live Preview Log")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder private var issues: some View {
        let items = project.panel.rows(of: project.result)
        if !items.isEmpty {
            List(items, id: \.offset) { row in
                IssueRow(item: row.element, place: row.offset, project: project)
            }
            .listStyle(.plain)
        } else if !project.panel.showsWarnings, project.result?.listed.contains(where: { !$0.isError && project.panel.matches($0) }) == true {
            ContentUnavailableView {
                Label("Warnings Hidden", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Show Warnings") { project.panel.showsWarnings = true }
            }
        } else if !project.panel.issueFilter.isEmpty {
            ContentUnavailableView.search(text: project.panel.issueFilter)
        } else {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
        }
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

private struct IssueRow: View {
    let item: LogItem
    let place: Int
    let project: ProjectModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Button { project.chooseIssue(place, focus: true) } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.message).lineLimit(place == project.chosenIssue ? nil : 3)
                        if let location = location(line: ":") {
                            Text(location).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("\(item.isError ? "Error" : "Warning"): \(item.message)")
            .accessibilityValue(location(line: ", line ") ?? "")
            if let file = item.missing { install(file) }
        }
        .listRowBackground(place == project.chosenIssue ? Color.accentColor.opacity(0.15) : nil)
        .contextMenu {
            if item.file != nil {
                Button(item.line == nil ? "Open File" : "Go to Line", systemImage: "arrow.right") { project.chooseIssue(place, focus: true) }
            }
            Button("Copy", systemImage: "document.on.document") { UIPasteboard.general.string = item.message }
        }
    }

    @ViewBuilder private func install(_ file: String) -> some View {
        if project.installing == file {
            ProgressView().accessibilityLabel("Installing")
        } else {
            Button("Install") { Task { await project.install(file) } }
                .buttonStyle(.bordered)
                .disabled(project.installing != nil)
        }
    }

    private func location(line: String) -> String? { item.file.map { file in item.line.map { "\(file)\(line)\($0)" } ?? file } }
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
