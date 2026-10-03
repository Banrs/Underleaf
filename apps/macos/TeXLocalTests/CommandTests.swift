import SwiftUI
import Testing
@testable import TeXLocal

/// The Mac's native key equivalents.
@MainActor
struct MenuCommandTests {
    @Test func noTwoCommandsShareAMacChord() {
        var seen: [KeyboardShortcut: MenuCommand] = [:]
        for command in MenuCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            #expect(seen[shortcut] == nil, "\(command.rawValue) and \(seen[shortcut]?.rawValue ?? "")")
            seen[shortcut] = command
        }
    }

    /// A PDF command or Go to PDF Position shows the PDF for now; only the toggle keeps it for later launches.
    @Test func onlyTheToggleKeepsThePDFShown() {
        let defaults = UserDefaults.standard, kept = defaults.object(forKey: DefaultsKey.showPDF)
        defer { defaults.set(kept, forKey: DefaultsKey.showPDF) }
        let app = AppModel()
        if app.showPDF { app.togglePDF() }
        #expect(!app.showPDF && !defaults.bool(forKey: DefaultsKey.showPDF))
        app.requestPDF(.find)
        #expect(app.showPDF && !defaults.bool(forKey: DefaultsKey.showPDF))
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

    /// The chords the Mac relies on, its own (`MenuCommand.shortcut`, HIG Keyboards) and the system's.
    @Test func eachChordHasItsItem() throws {
        let chords: [(String, NSEvent.ModifierFlags, String)] = [
            ("g", .command, "Find Next"), ("g", [.command, .shift], "Find Previous"),
            ("f", .command, "Find…"), ("f", [.command, .option], "Find and Replace…"),
            ("s", [.command, .control], "Sidebar"), ("0", .command, "Actual Size"),
            ("9", .command, "Fit Width"), ("9", [.command, .option], "Fit Height"),
            ("l", [.command, .shift], "Build Panel"), ("i", [.command, .option], "Inspector"),
            (",", .command, "Settings…"), ("o", .command, "Open…"), ("p", .command, "Print…"), ("p", [.command, .shift], "Page Setup…"),
            (".", .command, "Stop"), ("w", [.command, .shift], MenuCommand.projectClose.title),
            ("e", [.command, .option], MenuCommand.editMath.title), ("j", [.command, .option], MenuCommand.syncForward.title)]
        for (key, modifiers, title) in chords {
            #expect(try item(key, modifiers).title.hasSuffix(title), "\(title)")
        }
        // Find in PDF… has no chord of its own: ⌥⌘F is Find and Replace….
        #expect(try item("Find in PDF…", in: menu("Edit")).keyEquivalent == "")
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
        #expect(titles(format) == ["Bold", "Italic", "Underline", "Section Level", "Comment Selection"])
        #expect(titles(insert).starts(with: ["Inline Math", "Display Math", "Equation", "Aligned Equations", "Symbols", "Greek"]))
        #expect(titles(insert).contains("Figure") && titles(insert).last == "References and Links")
    }

    /// Insert's maths items say what they put in; its symbols are grids of TeX's glyphs, in full
    /// rows, each glyph with its command as help and its name and command for VoiceOver, and a
    /// chosen one isn't marked.
    @Test func mathShowsWhatItInserts() throws {
        let insert = try menu("Insert")
        #expect(insert.items.prefix(4).map(\.subtitle) == ["$ … $", "\\[ … \\]", "\\begin{equation}", "\\begin{align}"])
        for (title, symbols) in symbolGroups {
            let rows = try #require(try item(title, in: insert).submenu).items.compactMap(\.submenu)
            #expect(rows.allSatisfy { $0.presentationStyle == .palette })
            #expect(Set(rows.map(\.items.count)) == [SymbolItems.columns(symbols.count)], "\(title)")
            let glyphs = rows.flatMap(\.items)
            #expect(glyphs.map(\.toolTip) == symbols.map(\.1))
            #expect(glyphs.allSatisfy { $0.image?.isTemplate == true && $0.title.hasSuffix(", " + ($0.toolTip ?? "")) })
        }
        // TeX's \epsilon and \phi, not \varepsilon's and \varphi's.
        let greek = Dictionary(uniqueKeysWithValues: symbolGroups[0].1.map { ($0.1, $0.0) })
        #expect(greek["\\epsilon"] == "ϵ" && greek["\\phi"] == "ϕ")
        let menu = NSHostingMenu(rootView: SymbolItems(project: nil))
        let row = try #require(all(menu).first { $0.submenu?.presentationStyle == .palette }?.submenu)
        row.performActionForItem(at: 1)
        #expect(row.items.allSatisfy { $0.state == .off })
    }

    /// Engine lists the engines even with no project to set one for, never an empty submenu.
    @Test func engineListsTheEngines() throws {
        let engine = try #require(try item("Engine", in: menu("Compile")).submenu)
        #expect(titles(engine).starts(with: ["pdfLaTeX", "XeLaTeX", "LuaLaTeX"]))
    }

    /// Share… as the HIG names it, there even with nothing to share.
    @Test func shareIsOneItem() throws {
        let file = try menu("File")
        #expect(file.items.filter { $0.title.hasPrefix("Share") }.map(\.title) == ["Share…"])
    }
}
