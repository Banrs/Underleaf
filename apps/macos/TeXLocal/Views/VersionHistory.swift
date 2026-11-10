import SwiftUI

struct SaveVersionSheet: View {
    let project: ProjectModel
    @State private var name = ""

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        DialogSheet(title: "Save Version", message: "Named versions stay in the version history however old they get.",
                    action: "Save", enabled: !trimmed.isEmpty) {
            try await project.saveVersion(named: trimmed)
        } fields: {
            DialogField(label: "Name", text: $name, prompt: "Required")
        }
    }
}

struct VersionHistorySheet: View {
    let project: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var app
    @State private var snapshots: [Snapshot]?
    @State private var selected = Selection()
    @State private var compared: (selection: Selection, result: Shown)?
    @State private var restoring = false
    @State private var confirmingRestoreAll: Snapshot?
    @State private var listFailure: String?
    @State private var restoreFailure: String?

    private struct Selection: Equatable {
        var version: Snapshot.ID?
        var file: String?
    }

    private enum Shown { case diff([DiffLine]), same, failed(String) }

    private static let listDates = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private var snapshot: Snapshot? { snapshots?.first { $0.id == selected.version } }
    private var file: String? { selected.file }
    private var shown: Shown? { compared?.selection == selected ? compared?.result : nil }
    private var restorable: Bool {
        guard case .diff = shown else { return false }
        return snapshot?.changed.contains { $0.path == file && $0.change != .deleted } == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VSplitView {
                    snapshotList
                    fileList
                }
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                comparison
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Restore File") { if let snapshot, let file { restore(snapshot, paths: [file]) } }
                    .disabled(!restorable || restoring)
                Button("Restore All") { confirmingRestoreAll = snapshot }
                    .disabled(snapshot == nil || restoring)
                if let restoreFailure { FailureText(text: restoreFailure) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .scenePadding()
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 440, idealHeight: 600)
        .task { await list() }
        .task(id: selected) { [selected] in await compare(selected) }
        .alert("Restore All Files to “\(confirmingRestoreAll?.title ?? "")”?", item: $confirmingRestoreAll) { snapshot in
            Button("Restore All") { restore(snapshot, paths: nil) }
            Button("Cancel", role: .cancel) {}
        } message: { snapshot in
            let time = snapshot.date.formatted(date: .long, time: .shortened)
            Text("Every file goes back to how it was on \(time). Files added since stay as they are, and the version history keeps the project as it is now.")
        }
    }

    private var snapshotList: some View {
        List(snapshots ?? [], selection: Binding(get: { selected.version }, set: selectVersion)) { snapshot in
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title).fontWeight(snapshot.name == nil ? .regular : .bold)
                Text(snapshot.date, formatter: Self.listDates)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Versions")
        .overlay {
            if let listFailure {
                ContentUnavailableView("Couldn’t Read the Version History", systemImage: "exclamationmark.triangle",
                                       description: Text(listFailure))
            } else if snapshots?.isEmpty == true {
                ContentUnavailableView("No Versions", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                                       description: Text("A version is kept as you save, at most every 10 minutes."))
            }
        }
    }

    private var fileList: some View {
        List(snapshot?.changed ?? [], id: \.path, selection: $selected.file) { change in
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.path.fileName)
                        if !change.path.parentFolder.isEmpty {
                            Text(change.path.parentFolder).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "document")
                }
                Spacer()
                let (letter, spoken): (String, LocalizedStringKey) = switch change.change {
                case .added: ("A", "Added")
                case .deleted: ("D", "Deleted")
                case .changed: ("M", "Changed")
                }
                Text(verbatim: letter)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(spoken)
            }
            .help(change.path)
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Changed Files")
    }

    @ViewBuilder private var comparison: some View {
        let name = file?.fileName ?? ""
        switch shown {
        case .diff(let rows):
            DiffView(rows: rows, font: Font(SourceTextView.font(named: app.fontName, size: CGFloat(app.fontSize), dark: colorScheme == .dark)))
        case .same:
            ContentUnavailableView("No Differences", systemImage: "equal",
                                   description: Text("“\(name)” is the same now as in this version."))
        case .failed(let message):
            ContentUnavailableView("Can’t Compare “\(name)”", systemImage: "exclamationmark.triangle", description: Text(message))
        case nil:
            if snapshot != nil, file == nil {
                ContentUnavailableView("No Changes", systemImage: "equal",
                                       description: Text("The files are as in the version before this one."))
            } else {
                Color.clear
            }
        }
    }

    private func list() async {
        do {
            let listed = try await project.session.call(ListVersions())
            snapshots = listed
            selectVersion(listed.first?.id)
        } catch {
            listFailure = error.localizedDescription
        }
    }

    private func selectVersion(_ version: Snapshot.ID?) {
        guard version != selected.version else { return }
        let file = snapshots?.first { $0.id == version }?.changed.first?.path
        selected = Selection(version: version, file: file)
    }

    private func compare(_ selection: Selection) async {
        guard !Task.isCancelled, selection == selected else { return }
        compared = nil
        guard let version = selection.version, let file = selection.file else { return }
        let result: Shown
        do {
            let rows = try await project.session.call(CompareVersion(id: version, path: file))
            result = rows.isEmpty ? .same : .diff(rows)
        } catch {
            result = .failed(error.localizedDescription)
        }
        guard !Task.isCancelled, selection == selected else { return }
        compared = (selection, result)
    }

    private func restore(_ snapshot: Snapshot, paths: [String]?) {
        (restoring, restoreFailure) = (true, nil)
        Task {
            do {
                try await project.restoreVersion(snapshot, paths: paths)
                dismiss()
            } catch {
                restoreFailure = error.localizedDescription
            }
            restoring = false
        }
    }
}

private struct DiffView: View {
    let rows: [DiffLine]
    let font: Font

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { row(rows[$0]) }
            }
            .font(font)
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private func row(_ row: DiffLine) -> some View {
        switch row {
        case .removed(let text): line("−", text, tint: .red).accessibilityLabel("Removed: \(text)")
        case .added(let text): line("+", text, tint: .green).accessibilityLabel("Added: \(text)")
        case .skipped(let count):
            Text("^[\(count) unchanged line](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(.quinary)
        case .same(let text): line(" ", text, tint: .clear)
        }
    }

    private func line(_ marker: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: marker).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: text.isEmpty ? " " : text)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.15))
    }
}
