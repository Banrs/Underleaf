import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

/// Renders search and filter fields at screen scale and 4x. Attach a 2x display for 2x renders.
/// TEST_RUNNER_TEXLOCAL_PIXELS=<folder> zsh tools/xctest.sh … -only-testing:TeXLocalTests/FieldPixelTests
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
        let window = pixelWindow(NSSize(width: 360, height: 120), dark: dark, key: key)
        showPixelWindow(window, on: screen)
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
            try await settlePixelLayout(passes: 5, interval: .milliseconds(30))
            let fields = view.descendants(of: NSSearchField.self)
            if pressing { for field in fields { (field.cell as? NSSearchFieldCell)?.searchButtonCell?.isHighlighted = true } }
            for field in fields { field.needsDisplay = true }
            written += try writeNativePixels("\(name)-\(suffix)", of: box, scale: scale, to: folder)
            if pressing { for field in fields { (field.cell as? NSSearchFieldCell)?.searchButtonCell?.isHighlighted = false } }
        }

        let bar = NSHostingView(rootView: NavigatorFilterBar(project: project, window: windowModel))
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
        (project.navigator.showsOnlyRecentIssues, project.navigator.showsOnlyErrors) = (true, true)
        try await shot("bar-issues-toggles-on", bar, height: bar.intrinsicContentSize.height)
        (project.navigator.showsOnlyRecentIssues, project.navigator.showsOnlyErrors) = (false, false)
        project.navigator.shown = .files
        project.navigator.showsOnlyRecentFiles = true
        try await shot("bar-files-toggle-on", bar, height: bar.intrinsicContentSize.height)
        project.navigator.showsOnlyRecentFiles = false

        for options in [false, true] {
            for text in ["", "intro"] {
                let field = FilterField(text: .constant(text), options: options ? [("Errors", .constant(true))] : []) {}.frame(width: 182)
                try await shot("filter\(options ? "-menu" : "")-\(text.isEmpty ? "empty" : "text")", NSHostingView(rootView: field), height: 40, width: 200)
            }
        }
        for text in ["", "intro"] {
            let hosted = NSHostingView(rootView: SearchField(text: .constant(text), prompt: "Search").frame(width: 182))
            try await shot("plain-search-\(text.isEmpty ? "empty" : "text")", hosted, height: 40, width: 200)
            if text.isEmpty { try await shot("plain-search-pressed", hosted, height: 40, width: 200, pressing: true) }
        }
        return written
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
