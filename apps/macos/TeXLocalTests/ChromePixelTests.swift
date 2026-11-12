import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import TeXLocal

/// Renders window chrome at 2x and 4x in light and dark. Headless renders omit Liquid Glass, list rows and scroll edges.
/// With TEST_RUNNER_TEXLOCAL_SCREEN set, a watcher captures the window and moves the pointer on a 2x display.
/// The harness writes numbered .req files (shot name window, move x y, click x y) and waits for .done.
/// TEST_RUNNER_TEXLOCAL_PIXELS=<folder> zsh tools/xctest.sh … -only-testing:TeXLocalTests/ChromePixelTests
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] != nil))
struct ChromePixelTests {
    private let folder = URL(filePath: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] ?? "", directoryHint: .isDirectory)
    private let requests = ProcessInfo.processInfo.environment["TEXLOCAL_SCREEN"].map { URL(filePath: $0, directoryHint: .isDirectory) }

    @Test func theChromeIsWrittenOut() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = try blankPDF(count: 3)
        let screen = Screen(requests: requests)
        for dark in [false, true] { try await shoot(dark: dark, screen: screen, data: pdf) }
        try await screen?.ask("quit")
    }

    private func shoot(dark: Bool, screen: Screen?, data: Data) async throws {
        let defaults = TestDefaults()
        let model = defaults.window()
        let views = WorkspaceViews(project: ProjectModel(id: "Pixels", window: model))
        let project = views.project
        let size = NSSize(width: 1300, height: 700)
        let workspace = WorkspaceController(window: model, views: views, size: size)
        let window = pixelWindow(size, dark: dark, key: screen == nil, style: [.titled, .resizable, .fullSizeContentView])
        workspace.view.setFrameSize(size)
        window.contentViewController = workspace
        window.toolbar = workspace.toolbar.toolbar
        window.title = "Pixels"
        // On a 2x screen when there is one, so the 2x renders are laid out at 2x.
        if let place = NSScreen.screens.first(where: { $0.backingScaleFactor == 2 }) {
            window.setFrameOrigin(NSPoint(x: place.visibleFrame.minX + 40, y: place.visibleFrame.maxY - window.frame.height - 40))
        } else {
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
        }
        if screen == nil { window.alphaValue = 0.01 }
        window.orderFrontRegardless()
        defer { workspace.close(); window.close() }
        let suffix = dark ? "dark" : "light"
        if let screen {
            try await settlePixelLayout()
            // A click in the title bar makes the test host active, with this window key; another app can take it back.
            for _ in 0..<5 where !(NSApp.isActive && window.isKeyWindow) {
                try await screen.ask("click", at: NSPoint(x: window.frame.midX, y: window.frame.maxY - 12))
                try await settlePixelLayout()
            }
            try #require(NSApp.isActive && window.isKeyWindow)
        }

        project.store.apply(.tree(Self.tree))
        project.tree.arrived()
        project.expandedFolders = ["chapters", "figures"]
        project.store.apply(.openFile(OpenFile(path: "main.tex", kind: .tex, text: true)))
        views.pdf.show(try #require(PDFDocument(data: data)))
        try await settlePixelLayout()

        func capture(_ name: String) async throws {
            guard let screen else { return }
            try #require(NSApp.isActive && window.isKeyWindow, "\(name) would show an inactive window")
            try await screen.ask("shot screen-\(name)-\(suffix) \(window.windowNumber)")
        }
        func hover(_ view: NSView, _ point: NSPoint) async throws {
            guard let screen else { return }
            try await screen.ask("move", at: window.convertPoint(toScreen: view.convert(point, to: nil)))
            try await settlePixelLayout()
        }

        let columns = workspace.columns.view
        func bar(_ name: String) async throws {
            try await settlePixelLayout()
            // The split accessory sits alongside the columns, so capture them from the workspace.
            workspace.view.displayIfNeeded()
            let bounds = columns.convert(columns.bounds, to: workspace.view)
            let bottom = workspace.view.isFlipped ? bounds.maxY - 48 : bounds.minY
            try write("status-\(name)-\(suffix)", workspace.view, NSRect(x: bounds.minX, y: bottom, width: bounds.width, height: 48))
            try await capture("status-\(name)")
        }
        project.store.apply(.build(Self.build(ok: false, issues: [(true, "main.tex"), (true, "main.tex"), (false, "refs.bib")])))
        try await bar("failed")
        if screen != nil {
            try await hover(columns, NSPoint(x: 40, y: 18))
            try await capture("status-failed-hover-build")
            try await hover(columns, NSPoint(x: columns.bounds.width - 80, y: 18))
            try await capture("status-failed-hover-page")
            try await hover(columns, NSPoint(x: columns.bounds.width / 2, y: 300))
        }
        project.store.apply(.build(Self.build(ok: true, issues: [(false, "main.tex")])))
        try await bar("succeeded")
        project.store.apply(.build(Self.build(ok: nil, issues: [])))
        try await bar("compiling")

        let sidebar = workspace.splitViewItems[0].viewController.view
        func navigator(_ name: String) async throws {
            try await settlePixelLayout()
            try write("navigator-\(name)-\(suffix)", sidebar, sidebar.bounds)
            try await capture("navigator-\(name)")
        }
        project.navigator.shown = .files
        project.navigator.fileSelection = nil
        try await navigator("files")
        project.navigator.fileSelection = "refs.bib"
        try await settlePixelLayout()
        if let list = sidebar.descendants(of: NSOutlineView.self).first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 }) {
            window.makeFirstResponder(list)
        }
        try await navigator("files-selected")
        window.makeFirstResponder(nil)
        try await navigator("files-selected-unfocused")
        project.navigator.shown = .issues
        try await navigator("issues")
        project.navigator.shown = .search
        project.search.replacing = true
        try await navigator("search")

        project.panel.shown = true
        try await settlePixelLayout()
        let area = columns.superview?.superview ?? columns
        try write("logs-bar-\(suffix)", area, NSRect(x: columns.convert(columns.bounds, to: area).minX, y: area.isFlipped ? area.bounds.maxY - 48 : 0,
                                                    width: columns.bounds.width, height: 48))
        try await capture("logs")
    }

    private static let tree: [TreeNode] = [
        treeFolder("chapters", [treeFile("chapters/intro.tex", .tex), treeFile("chapters/method.tex", .tex)]),
        treeFolder("figures", [treeFile("figures/plot.png", .image), treeFile("figures/diagram.pdf", .pdf)]),
        treeFile("main.tex", .tex, main: true),
        treeFile("refs.bib", .bib),
        treeFile("mystyle.sty", .text),
        treeFile("notes.txt", .text),
        treeFile("data.csv", .text),
        treeFile("archive.zip", .other),
    ]

    /// A finished build when `ok` is set, otherwise one compiling.
    private static func build(ok: Bool?, issues: [(error: Bool, file: String)]) -> BuildState {
        let items = issues.enumerated().map { index, issue in
            logItem(issue.error ? .error : .warning, issue.error ? "Undefined control sequence." : "Citation undefined.",
                    file: issue.file, line: 10 + index)
        }
        let result = ok.map { CompileResult(ok: $0, stopped: false, durationMs: 2340, pdf: $0 ? "/tmp/main.pdf" : nil, badBoxes: []) }
        return BuildState(compiling: ok == nil, auto: false, outdated: false, result: result, issues: items, lines: [:])
    }

    private func write(_ name: String, _ view: NSView, _ rect: NSRect) throws {
        view.displayIfNeeded()
        try writeScaledPixels(name, of: view, in: rect, to: folder)
    }
}

/// Asks the watcher outside the test to capture windows and move the pointer, which the test host may not do itself.
@MainActor private final class Screen {
    private let folder: URL
    private var count = 0

    init?(requests: URL?) {
        guard let requests else { return nil }
        folder = requests
    }

    func ask(_ request: String) async throws {
        count += 1
        let name = String(format: "%04d", count)
        try request.write(to: folder.appending(path: "\(name).req"), atomically: true, encoding: .utf8)
        try await waitUntil(timeout: .seconds(20)) { FileManager.default.fileExists(atPath: folder.appending(path: "\(name).done").path) }
    }

    /// A point in AppKit's screen space, sent in the event system's, which starts at the main screen's top left.
    func ask(_ verb: String, at point: NSPoint) async throws {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        try await ask("\(verb) \(Int(point.x.rounded())) \(Int((top - point.y).rounded()))")
    }
}
