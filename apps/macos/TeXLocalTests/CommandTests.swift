import SwiftUI
import Testing
@testable import TeXLocal

struct MenuCommandTests {
    @Test func noTwoCommandsShareAMacChord() {
        var seen: [KeyboardShortcut: MenuCommand] = [:]
        for command in MenuCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            #expect(seen[shortcut] == nil, "\(command) and \(seen[shortcut].map { "\($0)" } ?? "")")
            seen[shortcut] = command
        }
    }

    @Test func findInProjectSearchesTheProjectsOnHome() {
        let app = AppModel()
        app.mainWindowIsKey = true
        #expect(app.isEnabled(.projectSearch, on: nil) && app.title(.projectSearch, on: nil) == "Find Project…")
        app.mainWindowIsKey = false
        #expect(!app.isEnabled(.projectSearch, on: nil))
    }

    @Test func theFormatCommandsAreLaTeXs() {
        let app = AppModel()
        let project = ProjectModel(id: "MenuCommandTests", app: app)
        let latex = [MenuCommand.editBold, .editItalic, .editUnderline, .editMath]
        #expect(!(latex + [.editComment, .syncInverse]).contains { app.isEnabled($0, on: project) })
        project.tree.show(.sources)
        project.openPath = "references.bib"
        #expect(!latex.contains { app.isEnabled($0, on: project) } && app.isEnabled(.editComment, on: project))
        project.openPath = "main.tex"
        #expect(latex.allSatisfy { app.isEnabled($0, on: project) } && app.isEnabled(.editComment, on: project))
        #expect(!latex.contains { app.isEnabled($0, on: nil) })
        project.shown = .build(URL(filePath: "/dev/null"))
        #expect(app.isEnabled(.syncInverse, on: project) && !app.isEnabled(.syncInverse, on: nil))
    }

    /// The one reckoning the pane, its header and View's command share: open for LaTeX unless folded, hidden for search results.
    @Test func theFileOutlineIsOpenForLaTeXUnlessFoldedOrSearched() {
        let app = AppModel()
        let collapsed = app.outlineCollapsed
        defer { app.outlineCollapsed = collapsed }
        let project = ProjectModel(id: "MenuCommandTests", app: app)
        app.outlineCollapsed = false
        project.tree.show(.sources)
        project.openPath = "references.bib"
        #expect(app.outlineState(of: project) == .folded && !app.outlineOpen(of: project) && !app.outlineOpen(of: nil))
        project.openPath = "main.tex"
        #expect(app.outlineState(of: project) == .open && app.outlineOpen(of: project))
        app.outlineCollapsed = true
        #expect(app.outlineState(of: project) == .folded)
        app.outlineCollapsed = false
        project.search.query = "needle"
        #expect(app.outlineState(of: project) == .hidden)
    }
}

struct MenuStructureTests {
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

    /// macOS 27 shows the images the app asks for and hides the system's, which the Edit menu leaves out of this.
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

    @Test func mathShowsWhatItInserts() throws {
        let insert = try menu("Insert")
        #expect(insert.items.prefix(4).map(\.subtitle) == ["$ … $", "\\[ … \\]", "\\begin{equation}", "\\begin{align}"])
        let groups = Menus.shared.symbolGroups
        #expect(!groups.isEmpty)
        for group in groups {
            let grid = try #require(try item(group.title, in: insert).submenu)
            let rows = grid.items.compactMap(\.submenu)
            #expect(rows.allSatisfy { $0.presentationStyle == .palette })
            // Widened past AppKit's own size for its palettes (`MathGlyphs.centre`).
            #expect(grid.minimumWidth > 0 && grid.size.width == grid.minimumWidth, "\(group.title)")
            #expect(Set(rows.map(\.items.count)) == [SymbolItems.columns(group.symbols.count)], "\(group.title)")
            let glyphs = rows.flatMap(\.items)
            #expect(glyphs.map(\.toolTip) == group.symbols.map(\.command))
            // The core's drawing, as a template the menu tints.
            #expect(glyphs.allSatisfy { $0.image?.isTemplate == true && $0.title.hasSuffix(", " + ($0.toolTip ?? "")) })
        }
        let menu = NSHostingMenu(rootView: SymbolItems(project: nil))
        let row = try #require(all(menu).first { $0.submenu?.presentationStyle == .palette }?.submenu)
        row.performActionForItem(at: 1)
        #expect(row.items.allSatisfy { $0.state == .off })
    }
}
