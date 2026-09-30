import SwiftUI
import PDFKit
import Testing
@testable import TeXLocal

/// The commands' chords: the shared table's (web/src/shortcuts.json) and the
/// Mac's own. `test/protocol.test.js` holds the command ids to the web's.
@MainActor
struct MenuCommandTests {
    @Test func acceleratorsBecomeMenuShortcuts() {
        #expect(MenuCommand.shortcut(for: "CmdOrCtrl+Return") == KeyboardShortcut(.return, modifiers: .command))
        #expect(MenuCommand.shortcut(for: "Ctrl+Shift+Return") == KeyboardShortcut(.return, modifiers: [.control, .shift]))
        #expect(MenuCommand.shortcut(for: "CmdOrCtrl+Plus") == KeyboardShortcut("=", modifiers: .command))
        #expect(MenuCommand.shortcut(for: "CmdOrCtrl+Shift+\\") == KeyboardShortcut("\\", modifiers: [.command, .shift]))
        #expect(MenuCommand.shortcut(for: "CmdOrCtrl+Alt+F") == KeyboardShortcut("f", modifiers: [.command, .option]))
    }

    /// The build copies the shared table in; without it every shared chord is gone.
    @Test func theSharedTableIsInTheApp() {
        #expect(MenuCommand.compileRun.accel == "CmdOrCtrl+Return")
        #expect(MenuCommand.editBold.shortcut == KeyboardShortcut("b", modifiers: .command))
    }

    @Test func everyAcceleratorParses() {
        for command in MenuCommand.allCases {
            for accel in [command.accel, command.macAccel].compactMap(\.self) {
                #expect(MenuCommand.shortcut(for: accel) != nil, "\(command.rawValue)")
            }
        }
    }

    @Test func noTwoCommandsShareAMacChord() {
        var seen: [KeyboardShortcut: MenuCommand] = [:]
        for command in MenuCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            #expect(seen[shortcut] == nil, "\(command.rawValue) and \(seen[shortcut]?.rawValue ?? "")")
            seen[shortcut] = command
        }
    }
}

/// Menus and toolbar use the same limits supplied by the current PDFKit view.
@MainActor
struct PDFCommandValidationTests {
    @Test func zoomCommandsRespectNativeScaleLimits() throws {
        let app = AppModel()
        let project = ProjectModel(id: "PDFCommandValidationTests", app: app)
        project.pdfURL = URL(filePath: "/tmp/zoom-validation.pdf")
        project.pdfVersion = 1
        let view = SyncPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let image = NSImage(size: NSSize(width: 612, height: 792), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        view.document = document
        view.minScaleFactor = 0.5
        view.maxScaleFactor = 2
        let controller = PDFController()
        controller.view = view
        app.pdfController = controller
        for scale in [0.5, 1, 2] {
            view.scaleFactor = scale
            // Validation reads PDFKit even before the scale notification is handled.
            #expect(app.isEnabled(.viewZoomIn, on: project) == (scale < 2))
            #expect(app.isEnabled(.viewZoomOut, on: project) == (scale > 0.5))
        }
        #expect(!app.isEnabled(.viewZoomIn, on: nil))
        project.pdfVersion = 0
        #expect(!app.isEnabled(.viewZoomOut, on: project))
    }
}

/// The running app's menu bar (HIG, The menu bar).
@MainActor
struct MenuStructureTests {
    /// Every item under `menu`, filled in as AppKit fills lazy menus before showing them.
    private func all(_ menu: NSMenu) -> [NSMenuItem] {
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) }
    }

    private func menu(_ title: String) throws -> NSMenu {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu, "\(title) menu")
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try #require(all(menu).first { $0.title == title }, "\(title)")
    }

    /// The item with this chord anywhere in the menu bar.
    private func item(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSMenuItem {
        let items = NSApp.mainMenu.map(all) ?? []
        return try #require(items.first { item in
            var mask = item.keyEquivalentModifierMask
            // AppKit also spells Shift as an upper-case key.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            return item.keyEquivalent.lowercased() == key && mask == modifiers
        }, "\(modifiers) \(key)")
    }

    /// The system's, which whatever has the keyboard answers: a text field from
    /// its undo manager, the source from its file's (`SourceEditor`).
    @Test func undoAndRedoAreTheSystems() throws {
        #expect(try item("z").action == Selector(("undo:")))
        #expect(try item("z", [.command, .shift]).action == Selector(("redo:")))
    }

    /// The chords the Mac relies on, its own (`MenuCommand.macAccel`, HIG Keyboards) and the system's.
    @Test func eachChordHasItsItem() throws {
        let chords: [(String, NSEvent.ModifierFlags, String)] = [
            ("g", .command, "Find Next"), ("g", [.command, .shift], "Find Previous"),
            ("f", .command, "Find…"), ("f", [.command, .option], "Find and Replace…"),
            ("s", [.command, .control], "Sidebar"), ("0", .command, "Actual Size"),
            ("9", .command, "Fit Width"), ("9", [.command, .option], "Fit Height"),
            ("l", [.command, .shift], "Build Panel"), ("i", [.command, .option], "Inspector"),
            ("o", .command, "Open…"), ("p", .command, "Print…"), ("p", [.command, .shift], "Page Setup…"),
            (".", .command, "Stop"), ("w", [.command, .shift], MenuCommand.projectClose.title),
            ("e", [.command, .option], MenuCommand.editMath.title), ("j", [.command, .option], MenuCommand.syncForward.title)]
        for (key, modifiers, title) in chords {
            #expect(try item(key, modifiers).title.hasSuffix(title), "\(title)")
        }
        // Find in PDF… has no chord of its own: ⌥⌘F is Find and Replace….
        #expect(try item("Find in PDF…", in: menu("Edit")).keyEquivalent == "")
    }

    /// The system's spelling commands, which the source's text view answers.
    @Test func spellingIsInTheEditMenu() throws {
        _ = try item(";")
        _ = try item(":")
    }

    @Test func theAppsMenusGoBetweenViewAndWindow() throws {
        let order = try #require(NSApp.mainMenu).items.map(\.title)
        let view = try #require(order.firstIndex(of: "View")), window = try #require(order.firstIndex(of: "Window"))
        #expect(Array(order[view...window]) == ["View", "Insert", "Compile", "Window"])
        #expect(try #require(order.firstIndex(of: "Format")) < view)
    }

    /// None of the system's text-editing items lost to a group of the app's own.
    @Test func editKeepsTheSystemsTextItems() throws {
        let edit = try menu("Edit")
        for title in ["Find", "Spelling and Grammar", "Substitutions", "Transformations", "Speech",
                      "Find in Project…", "Find in PDF…", "Go to Line…"] {
            #expect(titles(edit).contains(title), "\(title)")
        }
        let find = try item("Find", in: edit).submenu
        #expect(find.map(titles) == ["Find…", "Find and Replace…", "Find Next", "Find Previous",
                                     "Use Selection for Find", "Jump to Selection"])
        #expect(try item("Use Selection for Find", in: edit).keyEquivalent == "e")
        #expect(try item("Jump to Selection", in: edit).keyEquivalent == "j")
        #expect(try item("Check Spelling While Typing", in: edit).action == #selector(NSTextView.toggleContinuousSpellChecking(_:)))
    }

    /// Format holds the text's attributes; what inserts text is Insert's.
    @Test func formatStylesAndInsertInserts() throws {
        let format = try menu("Format"), insert = try menu("Insert")
        #expect(titles(format) == ["Bold", "Italic", "Section Level", "Comment Selection"])
        #expect(titles(insert).starts(with: ["Inline Math", "Display Math", "Equation", "Aligned Equations", "Symbols", "Greek"]))
        #expect(titles(insert).contains("Figure") && titles(insert).last == "References and Links")
    }

    /// Share… as the HIG names it, there even with nothing to share.
    @Test func shareIsOneItem() throws {
        let file = try menu("File")
        #expect(file.items.filter { $0.title.hasPrefix("Share") }.map(\.title) == ["Share…"])
    }
}

/// Edit › Find's items go down the responder chain to the window, which routes
/// them to the pane with the keyboard (`MainWindowController`).
@MainActor
struct FindRoutingTests {
    /// A find bar's field editor passes the items on, where the shared one
    /// would take them and turn them off.
    @Test func aFindFieldsEditorPassesFindOn() {
        let editor = FindPassingTextView()
        editor.isFieldEditor = true
        let window = Responder()
        editor.nextResponder = window
        let item = NSMenuItem(title: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)),
                              keyEquivalent: "g")
        item.tag = NSTextFinder.Action.nextMatch.rawValue
        #expect(editor.validateMenuItem(item))
        editor.performFindPanelAction(item)
        #expect(window.done == [.nextMatch])
        // A Find the pane can't do is off.
        item.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        #expect(!editor.validateMenuItem(item))
    }

    /// Stands in for the window: answers every Find item but Replace.
    private final class Responder: NSResponder, NSMenuItemValidation {
        var done: [NSTextFinder.Action] = []

        @objc func performFindPanelAction(_ sender: Any?) {
            if let tag = (sender as? NSMenuItem)?.tag, let action = NSTextFinder.Action(rawValue: tag) { done.append(action) }
        }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            item.tag != NSTextFinder.Action.showReplaceInterface.rawValue
        }
    }
}
