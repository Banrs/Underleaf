import SwiftUI

struct LogPane: View {
    let text: String
    let filter: String
    let hiddenKinds: Set<LogKind>
    let title: String
    @State private var filtered: String?

    var body: some View {
        let filtering = !filter.isEmpty || !hiddenKinds.isEmpty
        // Until a new filter's lines arrive, the last filter's stay, even if there were none.
        let shown = filtering ? filtered ?? text : text
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
            if let lines = await Self.lines(of: text, with: filter, hiding: hiddenKinds), !Task.isCancelled { filtered = lines }
        }
    }

    @concurrent private nonisolated static func lines(of text: String, with filter: String, hiding hidden: Set<LogKind>) async -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kinds = hidden.isEmpty ? nil : Syntax.call(LogKinds(log: text)).flatMap { $0.count == lines.count ? $0 : nil }
        var kept: [Substring] = []
        for (index, line) in lines.enumerated() {
            if Task.isCancelled { return nil }
            if let kinds, hidden.contains(kinds[index]) { continue }
            if filter.isEmpty || line.localizedCaseInsensitiveContains(filter) { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }
}
