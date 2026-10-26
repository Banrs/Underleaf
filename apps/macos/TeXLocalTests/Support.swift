import Foundation
@testable import TeXLocal

struct TimedOut: Error {}

func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

nonisolated final class TestDefaults {
    private let name = "TeXLocalTests." + UUID().uuidString
    let store: UserDefaults

    init() { store = UserDefaults(suiteName: name)! }

    deinit { UserDefaults.standard.removePersistentDomain(forName: name) }
}

func newProject(template: String = "article") async throws -> ProjectInfo {
    try await Core.shared.call("create_project", ["name": "Test " + UUID().uuidString, "template": template], as: ProjectInfo.self)
}
