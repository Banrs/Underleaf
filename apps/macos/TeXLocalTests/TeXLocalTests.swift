import SwiftUI
@testable import TeXLocal

/// What a timed-out wait last saw, so a failure on a machine we can't watch says why.
struct TimedOut: Error {
    var state = ""
}

/// Polls `condition` on the main actor until it holds; throws once `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool,
               state: () -> String = { "" }) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut(state: state()) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Two lengths equal to within half a point, as layout rounds them.
func isClose(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 0.5) -> Bool {
    abs(a - b) <= tolerance
}

/// A regular push button's fitting height, as the system draws it.
@MainActor
func regularControlHeight() -> CGFloat {
    NSHostingView(rootView: Button("Done") {}.controlSize(.regular)).fittingSize.height
}
