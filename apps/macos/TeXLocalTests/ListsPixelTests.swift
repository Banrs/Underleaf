import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

/// Writes the lists and popovers (completions and the Open Quickly list, Quick Help with a reference picture, the math
/// preview, issue boxes, the Symbol Library, the log pane, and the search navigator's header and empty states) as PNGs, in
/// each drawing state at native scale and 4x. Attach a 2x display for native 2x. Headless renders draw no Liquid Glass or
/// list rows, so the popovers show without their glass and the search results without their rows.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] != nil))
struct ListsPixelTests {
    private let folder = URL(filePath: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] ?? "", directoryHint: .isDirectory)

    @Test func everyListAndPopoverInEveryStateIsWrittenOut() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = TestDefaults()
        let windowModel = defaults.window()
        var written = 0
        for screen in NSScreen.screens {
            for dark in [false, true] {
                for key in [false, true] {
                    written += try await shoot(windowModel, on: screen, dark: dark, key: key)
                }
            }
        }
        #expect(written > 0)
    }

    private func shoot(_ windowModel: WindowModel, on screen: NSScreen, dark: Bool, key: Bool) async throws -> Int {
        let window = pixelWindow(NSSize(width: 360, height: 120), dark: dark, key: key)
        showPixelWindow(window, on: screen)
        defer { window.close() }
        let scale = Int(window.backingScaleFactor)
        let suffix = "\(dark ? "dark" : "light")-\(key ? "key" : "inactive")"
        var written = 0
        func shot(_ name: String, _ view: NSView, _ size: NSSize) async throws {
            let box = NSView(frame: NSRect(origin: .zero, size: size))
            view.frame = box.bounds
            box.addSubview(view)
            window.contentView = box
            window.setContentSize(size)
            try await settlePixelLayout(passes: 5, interval: .milliseconds(30))
            written += try writeNativePixels("\(name)-\(suffix)", of: box, scale: scale, to: folder)
        }
        /// Shows the view at its fitting size, or in the width or height given.
        func hosted(_ name: String, width: CGFloat? = nil, height: CGFloat? = nil, _ content: some View) async throws {
            let host = NSHostingView(rootView: content)
            let fitting = host.fittingSize
            try await shot(name, host, NSSize(width: width ?? fitting.width.rounded(.up), height: height ?? fitting.height.rounded(.up)))
        }

        let look = CompletionLook()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        (look.font, look.boldFont, look.typed) = (font, NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), 4)
        look.height = (font.ascender - font.descender + font.leading).rounded(.up) + 8
        let completions = ChoiceRows<Completion> { [$0.label] }
        completions.items = ["\\section", "\\subsection", "\\subsubsection*", "\\setlength"].map { label in
            Completion(label: label, text: label, fields: [], detail: label.hasPrefix("\\sub") ? "Sectioning" : nil)
        }
        for (selection, width) in [(0, 280.0), (2, 280), (2, 150)] {
            completions.selection = selection
            try await hosted("completions-\(selection)-\(Int(width))", width: width, height: 4 * look.height + 10,
                             CompletionRowsView(rows: completions, look: look) { _ in })
        }

        let files = ChoiceRows<String> { [$0] }
        files.items = ["chapters/introduction-and-motivation.tex", "main.tex", "refs.bib"]
        files.selection = 1
        try await hosted("open-quickly-list", width: 240, height: 3 * OpenQuickly.rowHeight + 10,
                         ChoiceList(rows: files, height: OpenQuickly.rowHeight, corner: OpenQuickly.corner, truncation: .middle,
                                    chosen: { _ in }) { Text($0) })

        let help = QuickHelp(kind: .label, title: "fig:plot", detail: "Figure 1: The measured values.",
                             place: FilePlace(file: "main.tex", line: 3, column: 0, length: 8), shown: nil)
        let pictures: [(String, ReferencePicture?)] = [("none", nil), ("paper", Self.picture(darkPaper: false)),
                                                       ("dark-paper", Self.picture(darkPaper: true))]
        for (name, picture) in pictures {
            try await hosted("quick-help-\(name)", QuickHelpView(help: help, picture: picture, font: font) { _ in })
        }

        let em = 13 * 1.21
        let drawing = Syntax.call(RenderMath(tex: "\\frac{a}{b} + x^2", display: true, size: em)) ?? nil
        try await hosted("math", MathView(tex: "\\frac{a}{b} + x^2", em: em, image: drawing.flatMap { NSImage(drawing: $0) }))
        try await hosted("math-error", MathView(tex: "\\frac{a}{", em: em, image: nil))

        let message = NSFont.systemFont(ofSize: 12)
        let boxes: [(String, Bool, Bool, Int, String?, CGFloat?)] = [("error", true, false, 1, "Undefined control sequence.", nil),
                                                                     ("warnings", false, false, 3, "Citation `knuth' undefined.", nil),
                                                                     ("live", true, true, 1, "Missing $ inserted.", nil),
                                                                     ("icon", false, true, 2, nil, nil),
                                                                     ("cut", true, false, 1, "Undefined control sequence.", 90)]
        for (name, error, live, issues, text, width) in boxes {
            try await hosted("issue-\(name)", width: width, height: 18,
                             IssueBox(isError: error, isLive: live, issues: issues, text: text, truncates: width != nil, font: message))
        }

        try await hosted("symbol-library", height: SymbolLibraryView.height, SymbolLibraryView(app: windowModel.app, insert: { _ in }, close: {}))

        let log = "This is pdfTeX, Version 3.141592653\n! Undefined control sequence.\nl.12 \\foo\nOutput written on main.pdf (3 pages)."
        try await hosted("log", width: 420, height: 120, LogPane(text: log, filter: "", hiddenKinds: [], title: "Build Log"))
        try await hosted("log-filtered", width: 420, height: 120, LogPane(text: log, filter: "Output", hiddenKinds: [], title: "Build Log"))
        try await hosted("log-no-match", width: 420, height: 120, LogPane(text: log, filter: "zzz", hiddenKinds: [], title: "Build Log"))

        // One navigator through each state, so a header that isn't measured again as it changes shows.
        let project = ProjectModel(id: "Pixels", window: windowModel)
        project.navigator.shown = .search
        let search = project.search
        let results = NSHostingView(rootView: SearchResults(project: project, field: FieldHandle()))
        let size = NSSize(width: 280, height: 300)
        try await shot("search-find", results, size)
        search.replacing = true
        try await shot("search-replacing", results, size)
        let hits = (1...3).map { SearchHit(file: "main.tex", line: $0, column: 0, length: 6, before: "a ", match: "needle", after: " b") }
        search.show(Usages(name: "needle", groups: [SearchGroup(file: "main.tex", hits: hits)]))
        try await shot("search-usages", results, size)
        search.show(Usages(name: "nothing", groups: []))
        try await shot("search-usages-none", results, size)
        search.query = ""
        await search.run { _ in [] }
        search.replacing = false
        try await shot("search-find-again", results, size)
        return written
    }

    /// A picture as PDFController cuts one: a bitmap at 2x of black marks on white.
    private static func picture(darkPaper: Bool) -> ReferencePicture {
        let size = NSSize(width: 160, height: 60)
        let rep = bitmap(size, scale: 2)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.black.setFill()
        NSRect(x: 20, y: 34, width: 120, height: 6).fill()
        NSAttributedString(string: "Figure 1", attributes: [.font: NSFont.systemFont(ofSize: 12)]).draw(at: NSPoint(x: 52, y: 10))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return ReferencePicture(image: image, darkPaper: darkPaper)
    }
}
