import SwiftUI

/// The bar's safe area reaches SwiftUI but not an AppKit scroll view, which takes it as an inset.
struct LogPane: View {
    let text: String
    let filter: String
    var title = "Build Log"
    /// Found off the main actor, not on every redraw of a log that can be megabytes; the last ones stay until the next.
    @State private var filtered: (filter: String, lines: String)?

    var body: some View {
        let current = filtered?.filter == filter ? filtered?.lines : nil
        let previous = filtered.flatMap { $0.lines.isEmpty ? nil : $0.lines }
        let shown = filter.isEmpty ? text : current ?? previous ?? text
        Group {
            if shown.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                GeometryReader { geometry in
                    LogTextView(text: shown, title: title, bottomInset: geometry.safeAreaInsets.bottom)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
        .task(id: [text, filter]) {
            guard !filter.isEmpty else { return filtered = nil }
            if let lines = await Self.lines(of: text, with: filter), !Task.isCancelled { filtered = (filter, lines) }
        }
    }

    @concurrent private nonisolated static func lines(of text: String, with filter: String) async -> String? {
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if Task.isCancelled { return nil }
            if line.localizedCaseInsensitiveContains(filter) { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }
}
