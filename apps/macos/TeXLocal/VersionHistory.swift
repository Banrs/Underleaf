import AppKit
import SwiftUI

struct SaveVersionSheet: View {
    let project: ProjectModel
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        DialogSheet(title: "Save Version", message: "Named versions stay in the version history however old they get.",
                    action: "Save", enabled: !trimmed.isEmpty, failure: { "Couldn’t Save the Version" }) {
            try await project.saveVersion(named: trimmed)
        } fields: {
            TextField("Name", text: $name)
                .focused($focused)
        }
        .defaultFocus($focused, true)
    }
}

struct VersionHistorySheet: View {
    let project: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [Snapshot]?
    @State private var chosen: Snapshot.ID?
    @State private var file: String?
    @State private var shown: Shown?
    @State private var restorable = false
    @State private var restoring = false
    @State private var confirmingRestoreAll = false
    @State private var alert: AppAlert?

    private enum Shown { case diff([DiffLine]), same, failed(String) }

    private static let listDates = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private var snapshot: Snapshot? { snapshots?.first { $0.id == chosen } }

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
                Button("Restore All") { confirmingRestoreAll = true }
                    .disabled(snapshot == nil || restoring)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .scenePadding()
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 440, idealHeight: 600)
        .task { await list() }
        .onChange(of: chosen) { file = snapshot?.changed.first?.path }
        .task(id: [chosen, file]) { await compare() }
        .alert("Restore All Files to “\(snapshot?.title ?? "")”?", isPresented: $confirmingRestoreAll,
               presenting: snapshot) { snapshot in
            Button("Restore All") { restore(snapshot, paths: nil) }
            Button("Cancel", role: .cancel) {}
        } message: { snapshot in
            let time = snapshot.date.formatted(date: .long, time: .shortened)
            Text("Every file goes back to how it was on \(time). Files added since stay as they are, and the version history keeps the project as it is now.")
        }
        .alert($alert)
    }

    private var snapshotList: some View {
        List(snapshots ?? [], selection: $chosen) { snapshot in
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
            if snapshots?.isEmpty == true {
                ContentUnavailableView("No Versions", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                                       description: Text("A version is kept as you save, at most every 10 minutes."))
            }
        }
    }

    private var fileList: some View {
        List(snapshot?.changed ?? [], id: \.path, selection: $file) { change in
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
            DiffView(rows: rows,
                     font: project.editor.textView.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
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
        guard let session = project.session else { return }
        do {
            let listed = try await project.core.call("session_history_list", ["session": session], as: [Snapshot].self)
            snapshots = listed
            chosen = listed.first?.id
        } catch {
            alert = AppAlert(String(localized: "Couldn’t Read the Version History"), error)
        }
    }

    private func compare() async {
        (shown, restorable) = (nil, false)
        guard let session = project.session, let chosen, let file else { return }
        let rows: [DiffLine]
        do {
            rows = try await project.core.call("session_history_compare", ["session": session, "id": chosen, "path": file],
                                               as: [DiffLine].self)
        } catch {
            if !Task.isCancelled { shown = .failed(error.localizedDescription) }
            return
        }
        guard !Task.isCancelled else { return }
        restorable = !rows.isEmpty && snapshot?.changed.first(where: { $0.path == file })?.change != .deleted
        shown = rows.isEmpty ? .same : .diff(rows)
    }

    private func restore(_ snapshot: Snapshot, paths: [String]?) {
        restoring = true
        Task {
            do {
                try await project.restoreVersion(snapshot, paths: paths)
                dismiss()
            } catch {
                alert = AppAlert(String(localized: "Couldn’t Restore “\(snapshot.title)”"), error)
            }
            restoring = false
        }
    }
}

private struct DiffView: View {
    let rows: [DiffLine]
    let font: NSFont

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { row(rows[$0]) }
            }
            .font(Font(font))
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private func row(_ row: DiffLine) -> some View {
        if let text = row.removed {
            line("−", text, tint: .red).accessibilityLabel("Removed: \(text)")
        } else if let text = row.added {
            line("+", text, tint: .green).accessibilityLabel("Added: \(text)")
        } else if let count = row.skipped {
            Text("^[\(count) unchanged line](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(.quinary)
        } else {
            line(" ", row.same ?? "", tint: .clear)
        }
    }

    private func line(_ marker: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: marker).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: text.isEmpty ? " " : text)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.15))
    }
}
