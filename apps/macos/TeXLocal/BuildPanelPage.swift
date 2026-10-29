import AppKit
import SwiftUI

struct BuildPanelPage: View {
    let project: ProjectModel

    var body: some View {
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

    @ViewBuilder private var issues: some View {
        let items = project.panel.rows(of: project.listed)
        if !items.isEmpty {
            IssueList(items: items, project: project)
        } else if !project.panel.showsWarnings, project.listed.contains(where: { !$0.isError && project.panel.matches($0) }) {
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

struct IssueRow: View {
    let item: LogItem
    let place: Int
    let project: ProjectModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            label
            if let fix = item.fix { offer(fix) }
        }
    }

    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message.text).lineLimit(place == project.chosenIssue ? nil : 3)
                if let explain = item.explain { Text(explain.text).foregroundStyle(.secondary) }
                if let location = location(line: ":") {
                    Text(location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        .help([item.message, item.explain].compactMap { $0?.text }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.isError ? "Error" : "Warning"): \(item.message.text)")
        .accessibilityValue([item.explain?.text, location(line: ", line ")].compactMap(\.self).joined(separator: " "))
    }

    @ViewBuilder private func offer(_ fix: Fix) -> some View {
        Spacer()
        if project.fixing == fix {
            ProgressView().controlSize(.small).accessibilityLabel(fix.title.text)
        } else {
            Button(fix.title.text) { run(fix) }
                .controlSize(.small)
                .disabled(project.fixing != nil)
                .help(fix.help.text)
        }
    }

    private func run(_ fix: Fix) { Task { if await confirmed(fix) { await project.run(fix) } } }

    private func confirmed(_ fix: Fix) async -> Bool {
        guard let confirm = fix.confirm else { return true }
        let alert = NSAlert()
        alert.messageText = "\(fix.title.text)?"
        alert.informativeText = confirm.text
        alert.addButton(withTitle: fix.title.text)
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = project.editor.textView.window else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    private func location(line: String) -> String? { item.file.map { file in item.line.map { "\(file)\(line)\($0)" } ?? file } }
}
