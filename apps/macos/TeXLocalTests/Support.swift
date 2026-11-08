import AppKit
import Testing
@testable import TeXLocal

struct TimedOut: Error {}

func waitUntil(timeout: Duration = .seconds(120), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A window showing `view` on screen, where PDFKit lays out and draws, without taking focus: a non-activating,
/// click-through, nearly transparent panel on every Space, since a window stays off the active Space while a full-screen
/// app holds it. A window the system finds hidden fails the test instead of measuring nothing.
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

/// A project workspace in a laid-out 1400 by 800 window, with the workspace's toolbar when asked.
func workspaceWindow(_ model: WindowModel, toolbar: Bool = false) -> (NSWindow, WorkspaceController) {
    let views = WorkspaceViews(project: ProjectModel(id: "P", window: model))
    let workspace = WorkspaceController(window: model, views: views, size: CGSize(width: 1400, height: 800))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = workspace
    if toolbar { window.toolbar = workspace.toolbar.toolbar }
    window.layoutIfNeeded()
    return (window, workspace)
}

/// Draws as the key window would, which a test host can't become on its own.
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

nonisolated final class TestDefaults {
    private let name = "TeXLocalTests." + UUID().uuidString
    let store: UserDefaults

    /// Starts with automatic compile off, so no test starts latexmk unless it turns compile on itself.
    init() {
        store = UserDefaults(suiteName: name)!
        store.set(false, forKey: DefaultsKey.autoCompile)
    }

    @MainActor func app() -> AppModel { AppModel(core: .shared, defaults: store) }

    @MainActor func window() -> WindowModel { WindowModel(app: app()) }

    deinit { UserDefaults.standard.removePersistentDomain(forName: name) }
}

func newProject(template: ProjectTemplate = .article) async throws -> ProjectInfo {
    try await Core.shared.call(CreateProject(name: "Test " + UUID().uuidString, template: template))
}
