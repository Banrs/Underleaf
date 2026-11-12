import AppKit
import PDFKit
import Testing
@testable import TeXLocal

/// Renders the status bar and Logs at screen scale and 4x, in light and dark with key and inactive windows.
/// Attach a 2x display for 2x renders.
/// TEST_RUNNER_TEXLOCAL_PIXELS=<folder> zsh tools/xctest.sh … -only-testing:TeXLocalTests/BarsPixelTests
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] != nil))
struct BarsPixelTests {
    private let folder = URL(filePath: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] ?? "", directoryHint: .isDirectory)

    @Test func theStatusBarsOtherItemsAndTheLogsPanelAreWrittenOut() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = 0
        for dark in [false, true] {
            for key in [false, true] {
                written += try await status(dark: dark, key: key)
            }
        }
        #expect(written > 0)
    }

    private func window(_ size: NSSize, on screen: NSScreen?, dark: Bool, key: Bool, style: NSWindow.StyleMask = [.titled]) -> NSWindow {
        let window = pixelWindow(size, dark: dark, key: key, style: style)
        let place = screen ?? NSScreen.screens.first { $0.backingScaleFactor == 2 } ?? NSScreen.screens.first
        showPixelWindow(window, on: place)
        return window
    }

    private func status(dark: Bool, key: Bool) async throws -> Int {
        let suffix = "\(dark ? "dark" : "light")-\(key ? "key" : "inactive")"
        var written = 0
        for width in [1300, 860, 700, 560] as [CGFloat] {
            let defaults = TestDefaults()
            let model = defaults.window()
            let views = WorkspaceViews(project: ProjectModel(id: "Pixels", window: model))
            let project = views.project
            let size = NSSize(width: width, height: 500)
            let workspace = WorkspaceController(window: model, views: views, size: size)
            let window = window(size, on: nil, dark: dark, key: key, style: [.titled, .resizable, .fullSizeContentView])
            workspace.view.setFrameSize(size)
            window.contentViewController = workspace
            defer { workspace.close(); window.close() }
            project.store.apply(.openFile(OpenFile(path: "main.tex", kind: .tex, text: true)))
            project.store.apply(.outline(Analysis(tree: [], words: 1234, headingStyles: [], packages: [])))
            views.pdf.show(try Self.pdf())
            let columns = workspace.columns.view
            func shot(_ name: String) async throws {
                try await settlePixelLayout()
                columns.displayIfNeeded()
                let rect = NSRect(x: 0, y: 0, width: columns.bounds.width, height: 48)
                let scales = [Int(window.backingScaleFactor), 4]
                try writeScaledPixels("status-\(name)-\(Int(width))-\(suffix)", of: columns, in: rect, to: folder, scales: scales)
                written += scales.count
            }

            project.store.apply(.build(BuildState(compiling: false, auto: false, outdated: true,
                                                  result: CompileResult(ok: true, stopped: false, durationMs: 1200, pdf: "/tmp/main.pdf", badBoxes: []),
                                                  issues: [], lines: [:])))
            project.store.apply(.documents([DocumentState(path: "main.tex", error: nil, conflict: .changed, asking: false)]))
            project.store.apply(.live(LiveState(phase: .running, engine: .pdflatex, halted: false, attention: false, failures: [], lines: [:])))
            try await shot("busy")
            project.store.apply(.documents([]))
            project.store.apply(.live(LiveState(phase: .stopped, engine: .pdflatex, halted: false, attention: true, failures: [], lines: [:])))
            project.store.apply(.build(BuildState(compiling: false, auto: false, outdated: false,
                                                  result: CompileResult(ok: false, stopped: false, durationMs: 900, pdf: nil, badBoxes: []),
                                                  issues: [], lines: [:])))
            try await shot("last-built")
            project.store.apply(.build(BuildState(compiling: false, auto: false, outdated: false,
                                                  result: CompileResult(ok: false, stopped: true, durationMs: 900, pdf: nil, badBoxes: []),
                                                  issues: [], lines: [:])))
            try await shot("stopped")

            let long = (1...80).map { "Line \($0) of a log long enough to scroll" }.joined(separator: "\n")
            project.store.apply(.buildLog("This is pdfTeX\nOutput written on main.pdf (1 page)."))
            project.panel.shown = true
            try await settlePixelLayout()
            let area = columns.superview?.superview ?? columns
            let above = columns.convert(columns.bounds, to: area)
            let panel = area.isFlipped ? NSRect(x: above.minX, y: above.maxY, width: above.width, height: area.bounds.maxY - above.maxY)
                : NSRect(x: above.minX, y: 0, width: above.width, height: above.minY)
            for (name, tab, filter, log) in [("log", PanelTab.log, "", ""), ("filtered", .log, "warn", ""), ("live", .texpresso, "", ""),
                                             ("long", .log, "", long)] {
                (project.panel.tab, project.panel.logFilter) = (tab, filter)
                if !log.isEmpty { project.store.apply(.buildLog(log)) }
                try await settlePixelLayout()
                area.displayIfNeeded()
                let scales = [Int(window.backingScaleFactor), 4]
                try writeScaledPixels("panel-\(name)-\(Int(width))-\(suffix)", of: area, in: panel, to: folder, scales: scales)
                written += scales.count
            }
        }
        return written
    }

    private static func pdf() throws -> PDFDocument {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        return try #require(PDFDocument(data: view.dataWithPDF(inside: view.bounds)))
    }
}
