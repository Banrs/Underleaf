import SwiftUI

struct LogsView: View {
    @Bindable var project: ProjectModel
    @State private var raw = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $raw) {
                    Text("Issues").tag(false)
                    Text("Raw Log").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let result = project.result {
                    Label(result.ok ? "Compiled" : "Failed", systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                    Text(String(format: "%.1fs", Double(result.durationMs) / 1000))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Close", systemImage: "xmark") { project.showLogs = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(8)
            Divider()
            if raw {
                ScrollView {
                    Text(project.result?.log ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            } else {
                issues
            }
        }
    }

    @ViewBuilder
    private var issues: some View {
        let items = (project.result?.errors ?? []) + (project.result?.warnings ?? [])
        if items.isEmpty {
            ContentUnavailableView(
                project.result == nil ? "Not Compiled Yet" : "No Issues",
                systemImage: project.result == nil ? "hammer" : "checkmark.circle"
            )
        } else {
            List(items) { item in
                Button {
                    if let file = item.file {
                        Task { await project.open(file, line: item.line) }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.isError ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.message).textSelection(.enabled)
                            if let file = item.file {
                                Text(item.line.map { "\(file):\($0)" } ?? file)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(item.file == nil)
            }
        }
    }
}
