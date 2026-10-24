#if os(macOS)
import AppKit
#endif
import SwiftUI

/// The panel's issues, the build's log or Live Preview's, under each app's own bar.
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

    /// "No Issues" before any build too: the status says whether one has run.
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

/// An issue with its explanation and place, and the core's fix for it.
struct IssueRow: View {
    let item: LogItem
    /// Its place in the list, which `chooseIssue` takes.
    let place: Int
    let project: ProjectModel
    #if os(iOS)
    @State private var confirming: LogItem.Fix?
    #endif

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            #if os(macOS)
            label
            #else
            Button { project.chooseIssue(place, focus: true) } label: {
                label.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
            #endif
            if let fix = item.fix { offer(fix) }
        }
        #if os(iOS)
        .alert(confirming.map { "\($0.title)?" } ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { fix in
            Button(fix.title) { Task { await project.run(fix) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text($0.confirm ?? "") }
        #endif
    }

    /// The explanation under the message, as Xcode shows an issue's note.
    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message).lineLimit(place == project.chosenIssue ? nil : 3)
                if let explain = item.explain { Text(explain).foregroundStyle(.secondary) }
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
        .help([item.message, item.explain].compactMap(\.self).joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.isError ? "Error" : "Warning"): \(item.message)")
        .accessibilityValue([item.explain, location(line: ", line ")].compactMap(\.self).joined(separator: " "))
    }

    /// As Xcode's Fix: a small button at the row's end, its progress in its place.
    @ViewBuilder private func offer(_ fix: LogItem.Fix) -> some View {
        Spacer()
        if project.fixing == fix {
            ProgressView().controlSize(.small).accessibilityLabel(fix.title)
        } else {
            Button(fix.title) { run(fix) }
                .controlSize(.small)
                #if os(iOS)
                .buttonStyle(.bordered)
                #endif
                .disabled(project.fixing != nil)
                .help(fix.help)
        }
    }

    #if os(macOS)
    private func run(_ fix: LogItem.Fix) { Task { if await confirmed(fix) { await project.run(fix) } } }

    /// AppKit's, as the window's other questions are: the fix's title on the default button (HIG, Alerts).
    private func confirmed(_ fix: LogItem.Fix) async -> Bool {
        guard let confirm = fix.confirm else { return true }
        let alert = NSAlert()
        alert.messageText = "\(fix.title)?"
        alert.informativeText = confirm
        alert.addButton(withTitle: fix.title)
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = project.editor.textView.window else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
    #else
    private func run(_ fix: LogItem.Fix) {
        if fix.confirm == nil { Task { await project.run(fix) } } else { confirming = fix }
    }
    #endif

    private func location(line: String) -> String? { item.file.map { file in item.line.map { "\(file)\(line)\($0)" } ?? file } }
}
