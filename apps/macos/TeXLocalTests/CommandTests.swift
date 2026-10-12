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
            #expect(seen[shortcut] == nil, "\(command) and \(seen[shortcut].map { "\($0)" } ?? "")")
            seen[shortcut] = command
        }
    }

    /// With no project open, Find in Project… finds a project, while the window is the one in front.
    @Test func findInProjectSearchesTheProjectsOnHome() {
        let app = AppModel()
        app.mainWindowIsKey = true
        #expect(app.isEnabled(.projectSearch, on: nil) && app.title(.projectSearch, on: nil) == "Find Project…")
        app.mainWindowIsKey = false
        #expect(!app.isEnabled(.projectSearch, on: nil))
    }

    /// Format's Bold, Italic, Underline and Inline Math are LaTeX's: off in another text file, where
    /// the commands for any text stay on, and with no file. Go to Source Position needs only a PDF.
    @Test func theFormatCommandsAreLaTeXs() {
        let app = AppModel()
        let project = ProjectModel(id: "MenuCommandTests", app: app)
        let latex = [MenuCommand.editBold, .editItalic, .editUnderline, .editMath]
        #expect(!(latex + [.editComment, .syncInverse]).contains { app.isEnabled($0, on: project) })
        project.openPath = "references.bib"
        #expect(!latex.contains { app.isEnabled($0, on: project) } && app.isEnabled(.editComment, on: project))
        project.openPath = "main.tex"
        #expect(latex.allSatisfy { app.isEnabled($0, on: project) } && app.isEnabled(.editComment, on: project))
        #expect(!latex.contains { app.isEnabled($0, on: nil) })
        project.shown = .build(URL(filePath: "/dev/null"))
        #expect(app.isEnabled(.syncInverse, on: project) && !app.isEnabled(.syncInverse, on: nil))
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

    /// The menus in the HIG's order, the Go commands in one menu, and no menu with icons on some of
    /// a group's items and not others (HIG, Menus): macOS 27 shows the images the app asks for and
    /// hides the system's, which the Edit menu leaves out of this.
    @Test func theMenuBarFollowsTheGuidelines() throws {
        let titles = try #require(NSApp.mainMenu).items.map(\.title)
        #expect(Array(titles.dropFirst()) == ["File", "Edit", "Format", "View", "Go", "Insert", "Compile", "Window", "Help"])
        let go = try menu("Go").items.map(\.title)
        #expect(go.contains("Go to Line…") && go.contains("Go to PDF Position") && go.contains("Go to Previous Issue"))
        #expect(try !all(menu("Edit")).contains { $0.title.hasPrefix("Go to") })
        let file = try all(menu("File")).map(\.title)
        #expect(file.contains("Export as PDF…") && !file.contains("Page Setup…"))
        #expect(try all(menu("Compile")).contains { $0.title == "Clean Build Folder" })
        for name in ["File", "Format", "View", "Go", "Compile"] {
            let groups = try menu(name).items.split(whereSeparator: \.isSeparatorItem)
            for group in groups {
                #expect(Set(group.map { $0.image != nil && $0.preferredImageVisibility == .visible }).count == 1,
                        "\(name): \(group.map(\.title)) \(group.map(\.preferredImageVisibility.rawValue))")
            }
        }
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
