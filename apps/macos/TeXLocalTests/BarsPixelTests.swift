import AppKit
import PDFKit
import Testing
@testable import TeXLocal

/// Renders the breadcrumb, status bar and Logs at screen scale and 4x, in light and dark with key and inactive windows.
/// Attach a 2x display for 2x renders.
/// TEST_RUNNER_TEXLOCAL_PIXELS=<folder> zsh tools/xctest.sh … -only-testing:TeXLocalTests/BarsPixelTests
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] != nil))
struct BarsPixelTests {
    private let folder = URL(filePath: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] ?? "", directoryHint: .isDirectory)

    @Test func theBreadcrumbInEveryStateIsWrittenOut() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = 0
        for screen in NSScreen.screens {
            for dark in [false, true] {
                for key in [false, true] {
                    written += try await crumb(on: screen, dark: dark, key: key)
                }
            }
        }
        #expect(written > 0)
    }

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

    private func crumb(on screen: NSScreen, dark: Bool, key: Bool) async throws -> Int {
        let window = window(NSSize(width: 240, height: 30), on: screen, dark: dark, key: key)
        defer { window.close() }
        let scale = Int(window.backingScaleFactor)
        let suffix = "\(dark ? "dark" : "light")-\(key ? "key" : "inactive")"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let crumb = Breadcrumb { _, _ in }
        box.addSubview(crumb)
        box.nextKeyView = crumb
        window.contentView = box
        window.setContentSize(box.frame.size)
        var written = 0
        func shot(_ name: String) async throws {
            try await settlePixelLayout()
            written += try writeNativePixels("crumb-\(name)-\(suffix)", of: box, scale: scale, to: folder, overlay: ring)
        }
        /// The focus ring, which AppKit draws apart from the view and so leaves out of a cached render, drawn from the
        /// focused view's mask.
        func ring(into rep: NSBitmapImageRep) {
            guard let focused = window.firstResponder as? NSView, focused.isDescendant(of: box) else { return }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let frame = focused.convert(focused.bounds, to: box)
            let transform = NSAffineTransform()
            transform.translateX(by: frame.minX, yBy: focused.isFlipped ? frame.maxY : frame.minY)
            transform.scaleX(by: 1, yBy: focused.isFlipped ? -1 : 1)
            transform.concat()
            focused.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSFocusRingPlacement.only.set()
                focused.drawFocusRingMask()
            }
        }
        /// The pointer entering or leaving the first item (10 pt in) or the last (10 pt before its end), through whichever
        /// tracking area covers that point, so it reads the same however the breadcrumb tracks the pointer.
        func pointer(_ type: NSEvent.EventType, _ index: Int) throws {
            let point = NSPoint(x: index == 0 ? 10 : crumb.bounds.maxX - 10, y: crumb.bounds.midY)
            let area = try #require(crumb.trackingAreas.first { $0.options.contains(.inVisibleRect) || $0.rect.contains(point) })
            let event = try #require(NSEvent.enterExitEvent(with: type, location: crumb.convert(point, to: nil), modifierFlags: [],
                                                           timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                           trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                                                           userData: nil))
            try #require(event.trackingArea === area)
            if type == .mouseEntered { crumb.mouseEntered(with: event) } else { crumb.mouseExited(with: event) }
        }

        for (name, chosen) in [("first", 0), ("other", 1)] {
            crumb.items = [Breadcrumb.Item(choices: ["Find", "Replace"], chosen: chosen),
                           Breadcrumb.Item(choices: ["Containing", "Matching Word"], chosen: chosen)]
            let size = crumb.intrinsicContentSize
            crumb.frame = NSRect(x: 2, y: (box.bounds.height - size.height) / 2, width: size.width, height: size.height)
            box.layoutSubtreeIfNeeded()
            try await shot(name)
            for index in [0, 1] {
                try pointer(.mouseEntered, index)
                try await shot("\(name)-hover-\(index)")
                try pointer(.mouseExited, index)
            }
            guard key else { continue }
            window.selectKeyView(following: box)
            try #require(window.firstResponder === crumb)
            try await shot("\(name)-focus-0")
            crumb.moveRight(nil)
            try await shot("\(name)-focus-1")
            window.makeFirstResponder(nil)
        }
        return written
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
