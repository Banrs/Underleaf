import AppKit
import Testing
@testable import TeXLocal

struct TimedOut: Error {}

/// Each wait ends as soon as its condition holds, so the timeout only stops a hung test: the core's tests gave up too
/// soon under load at 20 s.
func waitUntil(timeout: Duration = .seconds(120), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A window showing `view` for PDFKit to lay out and draw, which it does only on screen, without taking focus: ordered
/// in front without becoming key, clicked through and all but transparent. It is a non-activating panel on every Space,
/// as a window stays off the active Space while a full-screen app has it. A window the system finds hidden fails the test
/// rather than letting it measure nothing.
func onScreen(_ view: NSView, size: NSSize = NSSize(width: 500, height: 600)) async throws -> NSWindow {
    let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    window.toolbar = NSToolbar()
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = true
    window.alphaValue = 0.01
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.hidesOnDeactivate = false
    view.frame = window.contentView?.bounds ?? .zero
    view.autoresizingMask = [.width, .height]
    window.contentView?.addSubview(view)
    window.orderFrontRegardless()
    try? await waitUntil(timeout: .seconds(1)) { window.occlusionState.contains(.visible) }
    try #require(window.occlusionState.contains(.visible))
    return window
}

nonisolated final class TestDefaults {
    private let name = "TeXLocalTests." + UUID().uuidString
    let store: UserDefaults

    init() { store = UserDefaults(suiteName: name)! }

    @MainActor func app() -> AppModel { AppModel(core: .shared, defaults: store) }

    @MainActor func window() -> WindowModel { WindowModel(app: app()) }

    deinit { UserDefaults.standard.removePersistentDomain(forName: name) }
}

func newProject(template: ProjectTemplate = .article) async throws -> ProjectInfo {
    try await Core.shared.call(CreateProject(name: "Test " + UUID().uuidString, template: template))
}
