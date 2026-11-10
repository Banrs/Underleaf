import AppKit
import SwiftUI
import Testing
@testable import TeXLocal

/// Writes the windows and sheets (Projects, the dialog sheets, Version History, Settings, the inspector, Quick Help and
/// Open Quickly) as PNGs, light and dark, key and inactive, at native scale and 4x. Attach a 2x screen for 2x layout.
/// Sheets are presented through the window's own modals and draw inactive,
/// as the test host never becomes active; the dialogs are also hosted alone in a key window, and `focus.txt` names what
/// each one focused. Version History and Open Quickly also show a project the core has open, so the versions' times
/// differ from run to run. Hover and pressed states need the pointer and aren't drawn, nor is Liquid Glass or what it holds.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] != nil))
struct SheetsPixelTests {
    private let folder = URL(filePath: ProcessInfo.processInfo.environment["TEXLOCAL_PIXELS"] ?? "", directoryHint: .isDirectory)

    @Test func everyWindowAndSheetIsWrittenOut() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let screen = try #require(NSScreen.screens.first { $0.backingScaleFactor == 2 }, "Attach a 2x screen")
        let defaults = TestDefaults()
        let model = defaults.window()
        let library = model.app.core.library
        // The core sends its own TeX status once at launch; the samples replace it after.
        try? await waitUntil(timeout: .seconds(30)) { library.tex != nil }
        await model.app.reloadProjects()
        let views = WorkspaceViews(project: ProjectModel(id: "Pixels", window: model))
        Self.fill(views.project)
        var focus: [String] = []
        for dark in [false, true] {
            for key in [false, true] {
                focus += try await shoot(model, views, on: screen, dark: dark, key: key)
            }
        }
        // Opened after the Projects renders, so the library it changes can't show in them.
        let info = try await newProject(template: .blank)
        let opened = WorkspaceViews(project: ProjectModel(id: info.id, window: model))
        try await opened.project.load()
        try await Self.keepVersions(of: opened.project, in: URL(filePath: info.path, directoryHint: .isDirectory))
        focus += try await shootOpened(model, opened, on: screen)
        #expect(await opened.project.close().value)
        try focus.joined(separator: "\n").write(to: folder.appending(path: "focus.txt"), atomically: true, encoding: .utf8)
    }

    private func shoot(_ model: WindowModel, _ views: WorkspaceViews, on screen: NSScreen, dark: Bool, key: Bool) async throws -> [String] {
        let app = model.app, project = views.project
        let window = Self.window(on: screen, dark: dark, key: key)
        defer { window.close() }
        let suffix = "\(dark ? "dark" : "light")-\(key ? "key" : "inactive")"
        var focus: [String] = []

        /// Hosts `view` alone at `size`; a list is focused, so its selection shows as a key window draws it.
        func hosted(_ name: String, _ view: some View, _ size: NSSize, list: Bool = false) async throws {
            let host = Self.host(view, model, views)
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.setContentSize(size)
            try await settlePixelLayout()
            if list, let table = host.descendants(of: NSTableView.self).first { window.makeFirstResponder(table) }
            try await settlePixelLayout()
            try write("\(name)-\(suffix)", host)
            focus.append("\(name)-\(suffix): \(Self.describe(window.firstResponder))")
        }

        app.core.library.apply(.tex(Self.texFound))
        app.core.library.apply(.projects([]))
        try await hosted("home-empty", HomeView(), NSSize(width: 720, height: 600), list: true)
        app.core.library.apply(.projects(Self.projects))
        try await hosted("home-projects", HomeView(), NSSize(width: 720, height: 600), list: true)

        try await hosted("dialog-new-empty", NewProjectSheet(draft: NewProjectDraft(template: .article, name: "")), NSSize(width: 390, height: 220))
        try await hosted("dialog-new-named", NewProjectSheet(draft: NewProjectDraft(template: .beamer, name: "Thesis")),
                         NSSize(width: 390, height: 220))
        try await hosted("dialog-save-version", SaveVersionSheet(project: project), NSSize(width: 390, height: 200))
        let failure = "The folder “Thesis” already exists in the projects folder, so nothing was created. Choose another name."
        try await hosted("failure-text", FailureText(text: failure).frame(width: 340).padding(), NSSize(width: 372, height: 100))
        try await hosted("failure-footer", Form { Section { Text("Name") } footer: { FailureText(text: failure) } }.formStyle(.grouped),
                         NSSize(width: 390, height: 160))

        for pane in [SettingsPane.general, .editor, .compiling, .pdf, .livePreview] {
            app.settingsPane = pane
            try await hosted("settings-\(pane.rawValue)", SettingsView(), NSSize(width: 500, height: 520))
        }
        try await hosted("inspector-found", InspectorView(project: project), NSSize(width: 280, height: 560))
        for (state, tex) in [("missing", Self.texMissing), ("no-texpresso", Self.texNoTeXpresso)] {
            app.core.library.apply(.tex(tex))
            for pane in [SettingsPane.compiling, .livePreview] {
                app.settingsPane = pane
                try await hosted("settings-\(pane.rawValue)-\(state)", SettingsView(), NSSize(width: 500, height: 520))
            }
            try await hosted("inspector-\(state)", InspectorView(project: project), NSSize(width: 280, height: 560))
        }
        app.core.library.apply(.tex(Self.texFound))

        let place = FilePlace(file: "chapters/intro.tex", line: 3, column: 0, length: 16)
        let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        for (name, help) in [("quick-help", QuickHelp(kind: .label, title: "sec:intro", detail: "\\label{sec:intro} in the section “Introduction”.",
                                                      place: place, shown: nil)),
                             ("quick-help-title", QuickHelp(kind: .command, title: "\\emph", detail: "", place: nil, shown: nil))] {
            try await hosted(name, QuickHelpView(help: help, picture: nil, font: bold) { _ in }, NSSize(width: 420, height: 120))
        }

        guard !key else { return focus }
        focus.append(try await sheet("new-project", in: window, model, views, suffix: suffix) {
            model.newProjectDraft = NewProjectDraft(template: .report, name: "Thesis")
        } dismiss: { model.newProjectDraft = nil })
        let prompts: [(String, Prompt)] = [("go-to-page", .gotoPage), ("go-to-line", .gotoLine), ("save-version", .saveVersion),
                                           ("add-citation", .addCitation), ("rename", .rename(SymbolName(kind: .label, name: "sec:intro"))),
                                           ("version-history-unread", .versionHistory)]
        for (name, prompt) in prompts {
            focus.append(try await sheet(name, in: window, model, views, suffix: suffix) { model.prompt = prompt } dismiss: { model.prompt = nil })
        }
        return focus
    }

    /// Version History and Open Quickly over a project the core has open, inactive as the sheet and panel draw.
    private func shootOpened(_ model: WindowModel, _ views: WorkspaceViews, on screen: NSScreen) async throws -> [String] {
        let window = Self.window(on: screen, dark: false, key: false)
        defer { window.close() }
        var focus: [String] = []
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            focus.append(try await sheet("version-history", in: window, model, views, suffix: "\(dark ? "dark" : "light")-inactive") {
                model.prompt = .versionHistory
            } dismiss: { model.prompt = nil })
        }

        // A closed Open Quickly panel lingers in the test host and keeps another from opening, so one panel draws both ways.
        window.contentView = NSView()
        window.setContentSize(NSSize(width: 1000, height: 700))
        OpenQuickly.show(for: views.project, over: window)
        let panel = try #require(window.childWindows?.first)
        defer { panel.close() }
        try await waitUntil(timeout: .seconds(10)) { panel.frame.height > OpenQuickly.fieldHeight }
        for dark in [false, true] {
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await settlePixelLayout()
            let suffix = "\(dark ? "dark" : "light")-inactive"
            try write("open-quickly-\(suffix)", try #require(panel.contentView))
            focus.append("open-quickly-\(suffix): \(Self.describe(panel.firstResponder))")
        }
        return focus
    }

    /// Presents a sheet through the window's modals and writes it, naming what it focused.
    private func sheet(_ name: String, in window: NSWindow, _ model: WindowModel, _ views: WorkspaceViews, suffix: String,
                       _ present: () -> Void, dismiss: () -> Void) async throws -> String {
        window.contentView = Self.host(WindowModals(window: model, project: views.project), model, views)
        window.setContentSize(NSSize(width: 1000, height: 700))
        try await settlePixelLayout()
        present()
        try await waitUntil(timeout: .seconds(10)) { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        sheet.appearance = window.appearance
        try await settlePixelLayout()
        try write("sheet-\(name)-\(suffix)", try #require(sheet.contentView))
        dismiss()
        try await waitUntil(timeout: .seconds(10)) { window.attachedSheet == nil }
        return "sheet-\(name)-\(suffix): \(Self.describe(sheet.firstResponder))"
    }

    private func write(_ name: String, _ view: NSView) throws {
        view.displayIfNeeded()
        let scale = Int(view.window?.backingScaleFactor ?? 1)
        for (label, rep) in [("\(scale)x", view.bitmapImageRepForCachingDisplay(in: view.bounds)), ("4x", bitmap(view.bounds.size, scale: 4))] {
            let rep = try #require(rep)
            try writePixels(view, in: view.bounds, using: rep, to: folder.appending(path: "\(name)@\(label).png"))
        }
    }

    /// A nearly transparent window on the 2x screen, drawn as key or inactive.
    private static func window(on screen: NSScreen, dark: Bool, key: Bool) -> NSWindow {
        let window = pixelWindow(NSSize(width: 400, height: 300), dark: dark, key: key)
        showPixelWindow(window, on: screen)
        return window
    }

    private static func host(_ view: some View, _ model: WindowModel, _ views: WorkspaceViews) -> NSView {
        let host = NSHostingView(rootView: AnyView(view.environment(model.app).environment(model).environment(views)))
        host.sizingOptions = []
        return host
    }

    private static func describe(_ responder: NSResponder?) -> String {
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return responder.map { "\(type(of: $0))" } ?? "none" }
        return "field editor of \((editor.delegate as? NSTextField)?.placeholderString ?? "a field")"
    }

    private static func fill(_ project: ProjectModel) {
        let settings = ProjectSettings(mainFile: "main.tex", engine: .xelatex, stopOnFirstError: false, shellEscape: true)
        project.store.apply(.project(ProjectState(name: "Thesis", root: "/Users/Shared/Thesis", settings: settings, problem: nil)))
        project.store.apply(.tree([
            TreeNode(name: "chapters", path: "chapters", kind: nil,
                     children: [TreeNode(name: "intro.tex", path: "chapters/intro.tex", kind: .tex, children: nil, main: false)], main: false),
            TreeNode(name: "main.tex", path: "main.tex", kind: .tex, children: nil, main: true),
            TreeNode(name: "refs.bib", path: "refs.bib", kind: .bib, children: nil, main: false),
        ]))
        project.tree.arrived()
    }

    /// Two named versions, the second adding a section and lengthening main.tex, and changes to main.tex since, so the
    /// newest version lists a changed and an added file and compares the first, main.tex, with now.
    private static func keepVersions(of project: ProjectModel, in root: URL) async throws {
        func write(_ path: String, _ lines: [String]) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        try write("main.tex", ["\\documentclass{article}", "\\begin{document}", "\\end{document}"])
        try await project.saveVersion(named: "Draft")
        var lines = ["\\documentclass{article}", "\\begin{document}"] + (1...20).map { "Line \($0) of the introduction." }
            + ["\\input{sections/methods}", "\\end{document}"]
        try write("main.tex", lines)
        try write("sections/methods.tex", ["The methods."])
        try await project.saveVersion(named: "Submitted")
        lines[4] = "Line 3, rewritten."
        lines.insert("A line added near the end.", at: 20)
        try write("main.tex", lines)
    }

    private static let texFound = TexStatus(available: true, latexmkVersion: "4.86", texDir: "/Library/TeX/texbin", found: "/Library/TeX/texbin",
                                            texpresso: "/opt/homebrew/bin/texpresso", texpressoDir: nil)
    private static let texMissing = TexStatus(available: false, latexmkVersion: nil, texDir: nil, found: nil,
                                              texpresso: "/opt/homebrew/bin/texpresso", texpressoDir: nil)
    private static let texNoTeXpresso = TexStatus(available: true, latexmkVersion: "4.86", texDir: "/Library/TeX/texbin",
                                                  found: "/Library/TeX/texbin", texpresso: nil, texpressoDir: nil)

    /// Edited on 1 January 2020, so the relative dates read the same from one run to the next.
    private static let projects = [
        ProjectInfo(id: "a", name: "Thesis", mtime: 1_577_836_800_000, mainFile: "main.tex", path: "/Users/Shared/Thesis",
                    opened: true, missing: false, pdf: nil),
        ProjectInfo(id: "b", name: "Lecture Notes", mtime: 1_577_836_800_000, mainFile: "notes.tex", path: "/tmp/Lecture Notes",
                    opened: false, missing: false, pdf: nil),
        ProjectInfo(id: "c", name: "Old Paper", mtime: 1_577_836_800_000, mainFile: "paper.tex", path: "/Volumes/Archive/Old Paper",
                    opened: true, missing: true, pdf: nil),
    ]
}
