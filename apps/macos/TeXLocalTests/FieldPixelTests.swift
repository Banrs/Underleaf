import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

/// Writes every search and filter field the app shows, in each state their drawing tells apart, as PNGs: once before and
/// once after a change to how they're drawn, then compare the two folders pixel for pixel.
/// `TEST_RUNNER_TEXLOCAL_PIXELS=<folder> zsh tools/xctest.sh … -only-testing:TeXLocalTests/FieldPixelTests`, which renders at
/// each screen's scale (attach a 2x display for 2x) and at 4x.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] != nil))
struct FieldPixelTests {
    private let folder = URL(filePath: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] ?? "", directoryHint: .isDirectory)

    @Test func everyFieldInEveryStateIsWrittenOut() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = TestDefaults()
        let windowModel = defaults.window()
        let project = ProjectModel(id: "Pixels", window: windowModel)
        var written = 0
        for screen in NSScreen.screens {
            for dark in [false, true] {
                for key in [false, true] {
                    written += try await shoot(project, windowModel, on: screen, dark: dark, key: key)
                }
            }
        }
        #expect(written > 0)
    }

    private func shoot(_ project: ProjectModel, _ windowModel: WindowModel, on screen: NSScreen, dark: Bool, key: Bool) async throws -> Int {
        let window = (key ? KeyWindow.self : NSWindow.self).init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
        window.alphaValue = 0.01
        window.orderFrontRegardless()
        defer { window.close() }
        let scale = Int(window.backingScaleFactor)
        let suffix = "\(dark ? "dark" : "light")-\(key ? "key" : "inactive")"
        var written = 0
        func shot(_ name: String, _ view: NSView, height: CGFloat, width: CGFloat = 340, pressing: Bool = false) async throws {
            let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            view.frame = box.bounds
            box.addSubview(view)
            window.contentView = box
            window.setContentSize(box.frame.size)
            try await settle()
            let fields = view.descendants(of: NSSearchField.self)
            if pressing { for field in fields { (field.cell as? NSSearchFieldCell)?.searchButtonCell?.isHighlighted = true } }
            for field in fields { field.needsDisplay = true }
            box.displayIfNeeded()
            for (label, rep) in [("\(scale)x", box.bitmapImageRepForCachingDisplay(in: box.bounds)), ("4x", fourTimes(box.bounds.size))] {
                guard let rep else { continue }
                box.cacheDisplay(in: box.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name)-\(suffix)@\(scale)x-\(label).png"))
                written += 1
            }
            if pressing { for field in fields { (field.cell as? NSSearchFieldCell)?.searchButtonCell?.isHighlighted = false } }
        }

        let bar = NavigatorFilterBar(project: project, window: windowModel)
        for navigator in Navigator.allCases {
            project.navigator.shown = navigator
            for text in ["", "intro"] {
                project.navigator[keyPath: navigator.filterText] = text
                try await shot("bar-\(navigator)-\(text.isEmpty ? "empty" : "text")", bar, height: bar.intrinsicContentSize.height)
            }
            project.navigator[keyPath: navigator.filterText] = ""
            try await shot("bar-\(navigator)-pressed", bar, height: bar.intrinsicContentSize.height, pressing: true)
        }
        project.navigator.shown = .issues
        project.navigator.hiddenIssueKinds = [.badBox]
        try await shot("bar-issues-some-hidden", bar, height: bar.intrinsicContentSize.height)
        project.navigator.hiddenIssueKinds = []

        let find = FindHeader(project: project, field: FieldHandle())
        try await shot("find-header", find, height: max(find.fittingSize.height, 60))
        try await shot("find-header-pressed", find, height: max(find.fittingSize.height, 60), pressing: true)

        for (name, symbol, options) in [("logs-filter", true, true), ("symbol-filter", true, false), ("plain-search", false, false)] {
            for text in ["", "intro"] {
                let field = SearchField(text: .constant(text), prompt: "Filter", symbol: symbol ? SearchField.filterSymbol : nil, textSize: .small,
                                        optionsTitle: options ? "Show" : nil, options: options ? [("Errors", .constant(true))] : [])
                    .controlSize(.regular)
                    .frame(width: 182)
                let hosted = NSHostingView(rootView: field)
                try await shot("\(name)-\(text.isEmpty ? "empty" : "text")", hosted, height: 40, width: 200)
                if text.isEmpty { try await shot("\(name)-pressed", hosted, height: 40, width: 200, pressing: true) }
            }
        }
        return written
    }

    private func fourTimes(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 4, pixelsHigh: Int(size.height) * 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private func settle() async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(30))
            await Task.yield()
        }
    }
}

private extension Navigator {
    var filterText: ReferenceWritableKeyPath<NavigatorModel, String> {
        switch self {
        case .files: \.fileFilter
        case .outline: \.outlineFilter
        case .search: \.searchFilter
        case .issues: \.issueFilter
        }
    }
}
