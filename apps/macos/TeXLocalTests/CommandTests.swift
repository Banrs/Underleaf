import SwiftUI
import Testing
@testable import TeXLocal

struct MenuCommandTests {
    private let defaults = TestDefaults()

    @Test func noTwoCommandsShareAMacChord() {
        let chords = Dictionary(grouping: MenuCommand.allCases.filter { $0.shortcut != nil }) { $0.shortcut! }
        #expect(chords.values.allSatisfy { $0.count == 1 }, "\(chords.values.filter { $0.count > 1 })")
    }

    @Test func theFormatCommandsAreLaTeXs() {
        let app = AppModel(defaults: defaults.store)
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

    @Test func theFileOutlineIsOpenForLaTeXUnlessFoldedOrSearched() {
        let app = AppModel(defaults: defaults.store)
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
            for group in try menu(name).items.split(whereSeparator: \.isSeparatorItem) {
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
            let grid = try #require(all(insert).first { $0.title == group.title }?.submenu, "\(group.title)")
            let rows = grid.items.compactMap(\.submenu)
            #expect(rows.allSatisfy { $0.presentationStyle == .palette })
            #expect(Set(rows.map(\.items.count)) == [SymbolItems.columns(group.symbols.count)], "\(group.title)")
            let glyphs = rows.flatMap(\.items)
            #expect(glyphs.map(\.toolTip) == group.symbols.map(\.command))
            #expect(glyphs.allSatisfy { $0.image?.isTemplate == true && $0.title.hasSuffix(", " + ($0.toolTip ?? "")) })
        }
    }
}

struct OpenQuicklyTests {
    @Test func theArrowsStopAtTheEndsAndNewMatchesChooseTheFirst() {
        let rows = ChoiceRows<QuickOpenItem> { [$0.title] }
        let item = QuickOpenItem(kind: "file", title: "main.tex", detail: "", path: "main.tex", line: nil)
        rows.items = [item, item, item]
        rows.move(-1)
        #expect(rows.selection == 0)
        for _ in 0..<3 { rows.move(1) }
        #expect(rows.selection == 2)
        rows.items = [item, item]
        #expect(rows.selection == 0)
    }
}
