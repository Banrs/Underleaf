import Foundation
@testable import TeXLocal

/// What a timed-out wait last saw, so a failure on a machine we can't watch says why.
struct TimedOut: Error {
    var state = ""
}

func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool,
               state: () -> String = { "" }) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut(state: state()) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Lets what is queued on the main actor, and what that queues in turn, run: for something that must not happen, where there is no condition to wait for.
func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

/// An empty defaults domain of a test's own, for an `AppModel` whose settings would otherwise go to the user's. A suite
/// holds one for each test, as Swift Testing makes the suite afresh for each, and it goes as the test ends.
nonisolated final class TestDefaults {
    private let name = "TeXLocalTests." + UUID().uuidString
    let store: UserDefaults

    init() {
        store = UserDefaults(suiteName: name)!
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    /// What was written, not what the app registers for a key nothing has set.
    func saved(_ key: String) -> Any? {
        UserDefaults.standard.persistentDomain(forName: name)?[key]
    }
}

func isClose(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 0.5) -> Bool {
    abs(a - b) <= tolerance
}

extension [TreeNode] {
    /// A main file and a bibliography, as the core lists them.
    static var sources: [TreeNode] {
        [TreeNode(type: .file, name: "main.tex", path: "main.tex", kind: .tex, children: nil),
         TreeNode(type: .file, name: "references.bib", path: "references.bib", kind: .bib, children: nil)]
    }
}
