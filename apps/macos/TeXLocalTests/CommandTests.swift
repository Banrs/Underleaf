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

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try #require(all(menu).first { $0.title == title }, "\(title)")
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
}
