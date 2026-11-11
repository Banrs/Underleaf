import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import TeXLocal

/// Renders the editor gutter, PDF marks, Find bar and columns at 2x and 4x in light and dark with key and inactive windows.
/// Attach a 2x display to lay out at 2x.
/// TEST_RUNNER_TEXLOCAL_PIXELS=<folder> zsh tools/xctest.sh … -only-testing:TeXLocalTests/EditorPDFPixelTests
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] != nil))
struct EditorPDFPixelTests {
    private let folder = URL(filePath: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] ?? "", directoryHint: .isDirectory)

    @Test func theGutterThePDFsMarksAndAnEmptyColumnAreWrittenOut() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            for key in [false, true] {
                let suffix = "\(dark ? "dark" : "light")-\(key ? "key" : "inactive")"
                try await editor(dark: dark, key: key, suffix: suffix)
                try await pdf(dark: dark, key: key, suffix: suffix)
                try await emptyColumn(dark: dark, key: key, suffix: suffix)
                try await workspace(dark: dark, key: key, suffix: suffix)
            }
        }
    }

    private func editor(dark: Bool, key: Bool, suffix: String) async throws {
        let editor = SourceEditor()
        let window = Self.window(NSSize(width: 420, height: 300), dark: dark, key: key)
        defer { window.close() }
        window.contentView = editor.scrollView
        editor.open(path: "main.tex", source: SourceDocument(text: Self.source))
        editor.shown = true
        window.makeFirstResponder(editor.textView)
        let text = editor.textView, view = editor.scrollView
        text.selection = .caret((Self.source as NSString).range(of: "Some text").location + 4)
        try await write("gutter-\(suffix)", view)
        text.gutterHover(true)
        try await write("gutter-hover-\(suffix)", view)
        let folds = text.foldable.keys.sorted()
        try #require(folds.count >= 3)
        text.toggleFold(line: folds[1])
        text.gutterHover(false)
        try await write("folded-\(suffix)", view)
        text.gutterHover(true)
        try await write("folded-hover-\(suffix)", view)
        text.selection = NSRange(location: 0, length: 12)
        try await write("folded-selection-\(suffix)", view)
        text.showsLineNumbers = false
        try await write("folded-hover-unnumbered-\(suffix)", view)
        text.showsLineNumbers = true
        text.fontSize = 18
        try await write("folded-hover-large-\(suffix)", view)
        let badge = try #require(text.foldMarks.first?.rect)
        #expect(text.foldClick(at: CGPoint(x: badge.midX, y: badge.midY)) && text.folds.isEmpty)
    }

    private func pdf(dark: Bool, key: Bool, suffix: String) async throws {
        let controller = PDFController(), view = controller.view
        let window = Self.window(NSSize(width: 500, height: 600), dark: dark, key: key)
        defer { window.close() }
        let content = try #require(window.contentView)
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        controller.show(try Self.examplePDF())
        try await settlePixelLayout(passes: 6)
        let page = try #require(view.document?.page(at: 0))
        view.mark([0: Self.badBoxes], press: { _ in })
        try await write("badboxes-\(suffix)", view)
        // Zooming resizes the marks with their pages, so each has to redraw its rounded ends at the new size.
        view.scaleFactor *= 1.5
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: view.displayBox).maxY)))
        try await write("badboxes-zoomed-\(suffix)", view)
        view.flash(CGRect(x: 72, y: 600, width: 160, height: 14), on: page)
        try await write("sync-mark-\(suffix)", view)
        // The mark fades on a timer, which a slow run could see out before the next render.
        view.removeMark()
        view.find.perform(.showFindInterface)
        try await write("find-bar-\(suffix)", view)
        view.find.close()
    }

    private func emptyColumn(dark: Bool, key: Bool, suffix: String) async throws {
        let defaults = TestDefaults()
        let model = defaults.window()
        let views = WorkspaceViews(project: ProjectModel(id: "Pixels", window: model))
        let window = Self.window(NSSize(width: 420, height: 300), dark: dark, key: key)
        defer { window.close() }
        let column = NSHostingView(rootView: SourceColumn(project: views.project).environment(views).environment(model.app).environment(model))
        column.frame = window.contentView?.bounds ?? .zero
        window.contentView = column
        try await write("source-column-empty-\(suffix)", column)
    }

    /// The workspace's columns as a window lays them out: the editor and the PDF either side of the divider, over the
    /// status bar across both.
    private func workspace(dark: Bool, key: Bool, suffix: String) async throws {
        let defaults = TestDefaults()
        let model = defaults.window()
        let views = WorkspaceViews(project: ProjectModel(id: "Pixels", window: model))
        let size = NSSize(width: 1000, height: 560)
        let workspace = WorkspaceController(window: model, views: views, size: size)
        let window = Self.window(size, dark: dark, key: key)
        defer { workspace.close(); window.close() }
        workspace.view.setFrameSize(size)
        window.contentViewController = workspace
        views.project.store.apply(.openFile(OpenFile(path: "main.tex", kind: .tex, text: true)))
        views.pdf.show(try Self.examplePDF())
        try await settlePixelLayout(passes: 6)
        views.editor.open(path: "main.tex", source: SourceDocument(text: Self.source))
        try await write("workspace-\(suffix)", workspace.columns.view)
    }

    private func write(_ name: String, _ view: NSView) async throws {
        try await settlePixelLayout(passes: 6)
        view.displayIfNeeded()
        try writeScaledPixels(name, of: view, in: view.bounds, to: folder)
    }

    /// On a 2x screen when there is one, so the 2x renders are laid out at 2x.
    private static func window(_ size: NSSize, dark: Bool, key: Bool) -> NSWindow {
        let window = pixelWindow(size, dark: dark, key: key)
        let screen = NSScreen.screens.first { $0.backingScaleFactor == 2 } ?? NSScreen.screens[0]
        showPixelWindow(window, on: screen)
        return window
    }

    private static let source = """
        \\documentclass{article}
        \\begin{document}
        \\section{Introduction}
        Some text before the list.
        \\begin{itemize}
          \\item The first item
          \\item The second item
        \\end{itemize}
        \\begin{equation}
          x = 1
        \\end{equation}
        \\end{document}
        """

    /// One underfull box beside a paragraph and one overfull box over lines that run past its margin.
    private static let badBoxes = [
        BadBoxArea(file: "main.tex", line: 4, tooWide: nil, message: "Underfull \\hbox (badness 10000) in paragraph",
                   area: ForwardLoc(page: 1, h: 72, v: 300, width: 300, height: 20, matches: []), overrun: 0),
        BadBoxArea(file: "main.tex", line: 6, tooWide: 12.5, message: "Overfull \\hbox (12.5pt too wide) in paragraph",
                   area: ForwardLoc(page: 1, h: 20, v: 100, width: 300, height: 40, matches: []), overrun: 50),
    ]

    private static func examplePDF() throws -> PDFDocument {
        let pages = (1...2).map { page in
            (1...40).map { "Page \(page), line \($0): words that run on across the page to its edge." }.joined(separator: "\n")
        }
        return try textPDF(pages)
    }
}
