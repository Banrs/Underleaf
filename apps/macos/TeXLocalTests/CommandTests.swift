import SwiftUI
import Testing
import WebKit
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

    @Test func theEditorKeepsTheChordsItImplements() {
        let ids = Set(MenuCommand.editorHostKeys.map(\.id))
        for id in ["compile.run", "edit.gotoLine", "view.zoomIn"] {
            #expect(ids.contains(id), "\(id)")
        }
        for id in ["edit.find", "edit.findNext", "edit.findPrevious", "edit.comment", "edit.undo", "edit.redo"] {
            #expect(!ids.contains(id), "\(id)")
        }
        // The Mac's own chords, which the page would otherwise see first.
        for id in ["project.open", "edit.findAndReplace", "view.toggleInspector", "view.actualSize", "compile.stop",
                   "file.pageSetup", "file.print"] {
            #expect(ids.contains(id), "\(id)")
        }
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
    /// its undo manager, the editor from CodeMirror's history.
    @Test func undoAndRedoAreTheSystems() throws {
        #expect(try item("z").action == #selector(EditorWebView.undo(_:)))
        #expect(try item("z", [.command, .shift]).action == #selector(EditorWebView.redo(_:)))
    }

    @Test func theEditorAnswersUndoFromItsHistory() {
        let view = EditorWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let undo = NSMenuItem(title: "Undo Typing", action: #selector(EditorWebView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(EditorWebView.redo(_:)), keyEquivalent: "Z")
        #expect(!view.validateUserInterfaceItem(undo) && !view.validateUserInterfaceItem(redo))
        view.history = (undo: true, redo: false)
        #expect(view.validateUserInterfaceItem(undo) && !view.validateUserInterfaceItem(redo))
        #expect(undo.title == "Undo")
        var steps: [Bool] = []
        view.step = { steps.append($0) }
        view.undo(nil)
        view.redo(nil)
        #expect(steps == [false, true])
    }

    @Test func findNextAndPreviousAreCommandG() throws {
        #expect(try item("g").title == "Find Next")
        #expect(try item("g", [.command, .shift]).title == "Find Previous")
    }

    /// The Mac's chords where the shared table's differ (`MenuCommand.macAccel`).
    @Test func theViewMenuHasTheMacsChords() throws {
        #expect(try item("s", [.command, .control]).title.hasSuffix("Sidebar"))
        #expect(try item("0").title == "Actual Size")
        #expect(try item("9").title == "Fit Width")
        #expect(try item("9", [.command, .option]).title == "Fit Height")
    }

    /// Find in PDF… has no chord of its own: ⌥⌘F is Find and Replace….
    @Test func findHasTheMacsChords() throws {
        #expect(try item("f").title == "Find…")
        #expect(try item("f", [.command, .option]).title == "Find and Replace…")
        #expect(try item("Find in PDF…", in: menu("Edit")).keyEquivalent == "")
    }

    @Test func theBottomPanelIsTheBuildPanel() throws {
        let title = try item("l", [.command, .shift]).title
        #expect(["Show Build Panel", "Hide Build Panel"].contains(title), "\(title)")
    }

    /// The system's spelling commands, which WebKit's spell checking answers.
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
        #expect(titles(insert).starts(with: ["Inline Math", "Display Math", "Symbols", "Reference"]))
        #expect(titles(insert).contains("Figure"))
    }

    /// The Mac-only commands have their HIG chords (HIG, Keyboards).
    @Test func theMacsCommandsHaveTheirChords() throws {
        let file = try menu("File"), view = try menu("View"), compile = try menu("Compile")
        #expect(try item("Open…", in: file).keyEquivalent == "o")
        #expect(try item("Print…", in: file).keyEquivalent == "p")
        let setup = try item("Page Setup…", in: file)
        #expect(setup.keyEquivalent.lowercased() == "p"
                && (setup.keyEquivalent == "P" || setup.keyEquivalentModifierMask.contains(.shift)))
        let inspector = try #require(view.items.first { $0.title.hasSuffix("Inspector") })
        #expect(inspector.keyEquivalent == "i" && inspector.keyEquivalentModifierMask == [.command, .option])
        #expect(try item("Stop", in: compile).keyEquivalent == ".")
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
        let editor = FindFieldEditor()
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
