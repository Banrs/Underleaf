import AppKit
import PDFKit
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

func bitmap(_ size: NSSize, scale: Int) -> NSBitmapImageRep? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)
    rep?.size = size
    return rep
}

func settlePixelLayout(passes: Int = 8, interval: Duration = .milliseconds(40)) async throws {
    for _ in 0..<passes {
        try await Task.sleep(for: interval)
        await Task.yield()
    }
}

func pixelWindow(_ size: NSSize, dark: Bool, key: Bool, style: NSWindow.StyleMask = [.titled]) -> NSWindow {
    let window = (key ? KeyWindow.self : NSWindow.self).init(contentRect: NSRect(origin: .zero, size: size),
                                                             styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    return window
}

func showPixelWindow(_ window: NSWindow, on screen: NSScreen?) {
    let frame = screen?.visibleFrame ?? .zero
    window.setFrameOrigin(NSPoint(x: frame.minX + 40, y: frame.minY + 40))
    window.alphaValue = 0.01
    window.orderFrontRegardless()
}

func writePixels(_ view: NSView, in rect: NSRect, using rep: NSBitmapImageRep, to file: URL,
                 overlay: ((NSBitmapImageRep) -> Void)? = nil) throws {
    view.cacheDisplay(in: rect, to: rep)
    overlay?(rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: file)
}

func writeScaledPixels(_ name: String, of view: NSView, in rect: NSRect, to folder: URL, scales: [Int] = [2, 4]) throws {
    for scale in scales {
        let rep = try #require(bitmap(rect.size, scale: scale))
        try writePixels(view, in: rect, using: rep, to: folder.appending(path: "\(name)@\(scale)x.png"))
    }
}

/// Native AppKit bitmap and an explicitly scaled 4x copy. Counts every bitmap that was available.
func writeNativePixels(_ name: String, of view: NSView, scale: Int, to folder: URL,
                       overlay: ((NSBitmapImageRep) -> Void)? = nil) throws -> Int {
    view.displayIfNeeded()
    var written = 0
    for (label, rep) in [("\(scale)x", view.bitmapImageRepForCachingDisplay(in: view.bounds)), ("4x", bitmap(view.bounds.size, scale: 4))] {
        guard let rep else { continue }
        try writePixels(view, in: view.bounds, using: rep, to: folder.appending(path: "\(name)@\(scale)x-\(label).png"), overlay: overlay)
        written += 1
    }
    return written
}

func textPDF(_ pages: [String]) throws -> PDFDocument {
    let document = PDFDocument()
    for text in pages {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        view.string = text
        let page = try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0))
        document.insert(page, at: document.pageCount)
    }
    return document
}

func textPDF(count: Int) throws -> PDFDocument { try textPDF((1...count).map { "Page \($0)" }) }

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
