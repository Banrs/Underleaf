import AppKit
import SwiftUI

/// The maths symbols in a standard utility panel the system styles, as Xcode keeps its Library on ⇧⌘L: searchable, by the
/// catalogue's categories after the recently used ones. A click inserts at the caret of the frontmost project, and the panel
/// becomes key only for its search field, so the editor keeps the keyboard.
final class SymbolLibrary: NSPanel {
    private static var shown: SymbolLibrary?

    static func toggle(app: AppModel) {
        if let shown, shown.app === app {
            return shown.isVisible ? shown.close() : shown.orderFront(nil)
        }
        shown?.close()
        let panel = SymbolLibrary(app: app)
        shown = panel
        panel.orderFront(nil)
    }

    private let app: AppModel

    private init(app: AppModel) {
        self.app = app
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        title = String(localized: "Symbol Library")
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        let host = NSHostingController(rootView: SymbolLibraryView(app: app, insert: { [unowned self] in insert($0) },
                                                                   close: { [unowned self] in close() }))
        host.sizingOptions = [.minSize]
        contentViewController = host
        let width = host.view.fittingSize.width
        contentMaxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        setContentSize(NSSize(width: width, height: SymbolLibraryView.height))
        if !app.savesLayout || !setFrameUsingName("Symbol Library") { center() }
        if app.savesLayout { setFrameAutosaveName("Symbol Library") }
    }

    private func insert(_ symbol: Symbol) {
        guard let project = SymbolLibraryView.target(app), project.sourceToolsEnabled else { return }
        project.views?.perform(.symbol(symbol.command))
        app.recentSymbols = Array(([symbol.command] + app.recentSymbols.filter { $0 != symbol.command }).prefix(app.recentLimit()))
        if isKeyWindow { NSApp.mainWindow?.makeKey() }
    }
}

struct SymbolLibraryView: View {
    let app: AppModel
    let insert: @MainActor (Symbol) -> Void
    let close: @MainActor () -> Void
    @State private var query = ""

    /// The macOS UI Kit's large control height, and the widest row the menu bar's palettes use.
    private static let tile: CGFloat = 28, columns = 7
    /// The panel's first height: Xcode's Library panel's, read from a capture of it (504 pt).
    static let height: CGFloat = 504

    static func target(_ app: AppModel) -> ProjectModel? { app.windows.lazy.compactMap(\.shownProject).first }

    static func sections(_ query: String, recents: [String]) -> [SymbolGroup] {
        let groups = Menus.shared.symbolGroups
        guard query.isEmpty else {
            return groups.compactMap { group in
                let found = group.symbols.filter { MathGlyphs.spokenName($0.glyph, $0.command).localizedCaseInsensitiveContains(query) }
                return found.isEmpty ? nil : SymbolGroup(title: group.title, symbols: found)
            }
        }
        let symbols = Dictionary(groups.flatMap(\.symbols).map { ($0.command, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = recents.compactMap { symbols[$0] }
        return (recent.isEmpty ? [] : [SymbolGroup(title: String(localized: "Recently Used"), symbols: recent)]) + groups
    }

    var body: some View {
        let sections = Self.sections(query, recents: app.recentSymbols)
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: String(localized: "Search Symbols"),
                        step: { _ in if let first = sections.first?.symbols.first { insert(first) } }, close: close)
                .padding()
            Divider()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tile)), count: Self.columns), alignment: .leading) {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            // A symbol can show both in Recently Used and in its category, and a grid's items need ids unique across it.
                            ForEach(section.symbols.map { [section.title, $0.command] }, id: \.self) { key in
                                let symbol = section.symbols.first { $0.command == key[1] }!
                                Button { insert(symbol) } label: {
                                    Text(verbatim: symbol.glyph).font(.title2).frame(width: Self.tile, height: Self.tile)
                                }
                                .buttonStyle(.borderless)
                                .help(symbol.command)
                                .accessibilityLabel(MathGlyphs.spokenName(symbol.glyph, symbol.command))
                            }
                        } header: {
                            Text(section.title).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            .disabled(Self.target(app)?.sourceToolsEnabled != true)
            .overlay { if sections.isEmpty { ContentUnavailableView.search(text: query) } }
        }
    }
}
