import AppKit

/// Aa's pull-down, grouped as Notes' Aa: Bold, Italic and Underline as one palette row, selected while the selection has
/// them; the class's levels, each numbered and in its own font, the caret's checked; then what goes in. Made again as it opens.
final class FormatMenu: NSObject, NSMenuDelegate {
    private let app: AppModel
    private let project: ProjectModel

    init(app: AppModel, project: ProjectModel) {
        self.app = app
        self.project = project
        super.init()
    }

    /// A menu for one toolbar item, with items from the first: its overflow copy may be made from it.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.autoenablesItems = false
        menu.delegate = self
        menuNeedsUpdate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let enabled = project.isLaTeX
        menu.items = [styleRow(enabled), NSMenuItem.separator()] + levelItems() + [NSMenuItem.separator()] + insertItems()
        for item in menu.items { item.isEnabled = enabled }
    }

    /// The palette is a submenu shown inline as one row (macOS 14).
    private func styleRow(_ enabled: Bool) -> NSMenuItem {
        let styles = project.editor.textStyles
        let on = [styles.bold != nil, styles.italic != nil, styles.underline != nil]
        let palette = NSMenu(title: "Style")
        palette.presentationStyle = .palette
        palette.selectionMode = .selectAny
        palette.autoenablesItems = false
        palette.items = [MenuCommand.editBold, .editItalic, .editUnderline].map { command in
            let item = self.item(command.title) { [app, project] in app.perform(command, on: project) }
            item.image = command.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: command.title) }
            item.isEnabled = enabled
            return item
        }
        palette.selectedItems = zip(palette.items, on).filter { $0.1 }.map { $0.0 }
        let row = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        row.submenu = palette
        return row
    }

    private func levelItems() -> [NSMenuItem] {
        let headings = project.headingStyles, current = project.headingLevel
        return headings.levels.map { level in
            let item = self.item(level.title) { [project] in project.editor.perform(.heading, level.command) }
            let font = Self.font(headings.font(level))
            let title = NSMutableAttributedString()
            if let marker = headings.marker(level) {
                title.append(NSAttributedString(string: marker + "\u{2002}", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            title.append(NSAttributedString(string: level.title, attributes: [.font: font]))
            item.attributedTitle = title
            item.state = level == current ? .on : .off
            return item
        }
    }

    private func insertItems() -> [NSMenuItem] {
        [item(MenuCommand.editMath.title) { [app, project] in app.perform(.editMath, on: project) },
         item(String(localized: "Display Math")) { [project] in project.editor.perform(.displayMath) }]
            + listTemplates.filter { $0.symbol != nil }.map { template in item(template.title) { [project] in project.insert(template) } }
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Action(run: action)
        return item
    }

    private final class Action {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }

    @objc private func run(_ item: NSMenuItem) {
        (item.representedObject as? Action)?.run()
    }

    /// A level at its weight and shape, its size LaTeX's scaled into a menu's range: \Huge's 2.5
    /// times the text comes out at 22 points, near Pages' Title.
    private static func font(_ style: HeadingStyles.Font) -> NSFont {
        let size = (NSFont.systemFontSize * pow(style.scale, 0.58)).rounded()
        var descriptor = NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular).fontDescriptor
        switch style.shape {
        case .upright: break
        case .italic: descriptor = descriptor.withSymbolicTraits(.italic)
        case .smallCaps:
            descriptor = descriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType,
                                                                          .selectorIdentifier: kLowerCaseSmallCapsSelector]]])
        }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
    }
}
