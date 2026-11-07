import SwiftUI

struct LogPane: View {
    let text: String
    let filter: String
    let hiddenKinds: Set<LogKind>
    let title: String
    @State private var filtered: (key: Key, lines: String)?

    private struct Key: Equatable {
        let filter: String, hiddenKinds: Set<LogKind>
    }

    var body: some View {
        let key = Key(filter: filter, hiddenKinds: hiddenKinds)
        let filtering = !filter.isEmpty || !hiddenKinds.isEmpty
        let current = filtered?.key == key ? filtered?.lines : nil
        let previous = filtered.flatMap { $0.lines.isEmpty ? nil : $0.lines }
        let shown = filtering ? current ?? previous ?? text : text
        Group {
            if shown.isEmpty, filtering {
                NoFilterResults()
            } else {
                GeometryReader { geometry in
                    LogTextView(text: shown, title: title, bottomInset: geometry.safeAreaInsets.bottom)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
        .task(id: [text, filter, hiddenKinds.map(\.title).sorted().joined(separator: ",")]) {
            guard filtering else { return filtered = nil }
            if let lines = await Self.lines(of: text, with: filter, hiding: hiddenKinds), !Task.isCancelled { filtered = (key, lines) }
        }
    }

    @concurrent private nonisolated static func lines(of text: String, with filter: String, hiding hidden: Set<LogKind>) async -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kinds = hidden.isEmpty ? nil : LogKind.of(lines)
        var kept: [Substring] = []
        for (index, line) in lines.enumerated() {
            if Task.isCancelled { return nil }
            if let kinds, hidden.contains(kinds[index]) { continue }
            if filter.isEmpty || line.localizedCaseInsensitiveContains(filter) { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }
}
