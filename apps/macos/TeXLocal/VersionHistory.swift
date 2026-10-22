import AppKit
import SwiftUI

/// As Pages' Save a Version: a name for the project as it is, which the history keeps however old it gets.
struct SaveVersionSheet: View {
    let project: ProjectModel
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        DialogSheet(title: "Save Version", message: "Named versions stay in the version history however old they get.",
                    action: "Save", enabled: !trimmed.isEmpty, failure: { "Couldn’t Save the Version" }) {
            guard let session = project.session else { return }
            let saved = try await project.core.call("session_history_save", ["session": session, "name": trimmed], as: Snapshot.self)
            project.notices.note(String(localized: "Saved Version “\(saved.title)”"))
        } fields: {
            TextField("Name", text: $name)
                .focused($focused)
        }
        .defaultFocus($focused, true)
    }
}

/// As the document apps' Browse All Versions, in a sheet over the workspace: the snapshots as a source list, the files the
/// chosen one changed beneath them, and the chosen file then against now as a unified diff.
struct VersionHistorySheet: View {
    let project: ProjectModel
    @Environment(\.dismiss) private var dismiss
    /// Nil until the core answers, so the list isn't empty meanwhile.
    @State private var snapshots: [Snapshot]?
    @State private var chosen: Snapshot.ID?
    @State private var file: String?
    @State private var shown: Shown?
    /// The snapshot has the file, and it differs now: a file added since is left alone by a restore.
    @State private var restorable = false
    @State private var restoring = false
    @State private var confirmingRestoreAll = false
    @State private var alert: AppAlert?

    private enum Shown { case diff([DiffLine]), same, failed(String) }

    /// As Finder's lists date files: Today at 14:05, Yesterday at 09:30, then the date.
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
            let time = snapshot.time.formatted(date: .long, time: .shortened)
            Text("Every file goes back to how it was on \(time). Files added since stay as they are, and the version history keeps the project as it is now.")
        }
        .alert($alert)
    }

    private var snapshotList: some View {
        List(snapshots ?? [], selection: $chosen) { snapshot in
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title).fontWeight(snapshot.name == nil ? .regular : .bold)
                Text(snapshot.time, formatter: Self.listDates)
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
                // Xcode's source control letters.
                Text(verbatim: change.change.letter)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(change.change.spoken)
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
        let answer: Comparison
        do {
            answer = try await project.core.call("session_history_compare", ["session": session, "id": chosen, "path": file],
                                                 as: Comparison.self)
        } catch {
            if !Task.isCancelled { shown = .failed(error.localizedDescription) }
            return
        }
        // Another file chosen meanwhile.
        guard !Task.isCancelled else { return }
        restorable = answer.old != nil && answer.old != answer.new
        shown = answer.old == answer.new ? .same : .diff(lineDiff(answer.old, answer.new))
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

private extension Snapshot.Change.Kind {
    var letter: String {
        switch self {
        case .added: "A"
        case .deleted: "D"
        case .changed: "M"
        }
    }

    var spoken: String {
        switch self {
        case .added: String(localized: "Added")
        case .deleted: String(localized: "Deleted")
        case .changed: String(localized: "Changed")
        }
    }
}

/// The removed lines on red and the added on green, as Xcode's comparison tints them, in the editor's font. Long lines
/// wrap, so each row's tint spans the pane.
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
        switch row {
        case .same(let text): line(" ", text, tint: .clear)
        case .removed(let text): line("−", text, tint: .red).accessibilityLabel("Removed: \(text)")
        case .added(let text): line("+", text, tint: .green).accessibilityLabel("Added: \(text)")
        case .skipped(let count):
            Text("^[\(count) unchanged line](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(.quinary)
        }
    }

    private func line(_ marker: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: marker).foregroundStyle(.secondary).accessibilityHidden(true)
            // A blank line keeps its height.
            Text(verbatim: text.isEmpty ? " " : text)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.15))
    }
}

nonisolated enum DiffLine: Equatable {
    case same(String), removed(String), added(String)
    /// Unchanged lines further than the context from any change, folded as a unified diff's hunks leave them out.
    case skipped(Int)
}

/// A longest common subsequence over the lines between the common head and tail, which is most files' edit; a middle too
/// big for its table shows as removed then added. Display only: the core restores whole files.
nonisolated func lineDiff(_ old: String?, _ new: String?, context: Int = 3) -> [DiffLine] {
    let (a, b) = (lines(old), lines(new))
    let head = zip(a, b).prefix { $0 == $1 }.count
    let tail = zip(a.dropFirst(head).reversed(), b.dropFirst(head).reversed()).prefix { $0 == $1 }.count
    let (x, y) = (Array(a[head..<(a.count - tail)]), Array(b[head..<(b.count - tail)]))
    var rows = a[..<head].map(DiffLine.same)
    if x.count * y.count > 4_000_000 {
        rows += x.map(DiffLine.removed) + y.map(DiffLine.added)
    } else {
        // `common[i][j]`: the longest common subsequence of x[i...] and y[j...].
        var common = [[Int32]](repeating: [Int32](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in x.indices.reversed() {
            for j in y.indices.reversed() {
                common[i][j] = x[i] == y[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
            }
        }
        var (i, j) = (0, 0)
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] {
                rows.append(.same(x[i]))
                (i, j) = (i + 1, j + 1)
            } else if j == y.count || (i < x.count && common[i + 1][j] >= common[i][j + 1]) {
                rows.append(.removed(x[i]))
                i += 1
            } else {
                rows.append(.added(y[j]))
                j += 1
            }
        }
    }
    rows += a[(a.count - tail)...].map(DiffLine.same)

    var shown = [Bool](repeating: false, count: rows.count)
    for (index, row) in rows.enumerated() {
        if case .same = row { continue }
        for near in max(0, index - context)...min(rows.count - 1, index + context) { shown[near] = true }
    }
    var folded: [DiffLine] = []
    for (row, shown) in zip(rows, shown) {
        if shown {
            folded.append(row)
        } else if case .skipped(let count)? = folded.last {
            folded[folded.count - 1] = .skipped(count + 1)
        } else {
            folded.append(.skipped(1))
        }
    }
    return folded
}

/// A file's lines as the editor counts them, at a carriage return alone too; an absent file has none.
private nonisolated func lines(_ text: String?) -> [String] {
    guard let text, !text.isEmpty else { return [] }
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    if text.last?.isNewline == true { lines.removeLast() }
    return lines
}
