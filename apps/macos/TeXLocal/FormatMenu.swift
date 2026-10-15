import AppKit

/// Aa's pull-down, as Pages' paragraph styles: Bold, Italic and Underline, checked where the
/// selection has them, Inline Math, then the levels the document's class has, each in its font
/// there, the caret's checked. Made again as it opens, for the selection and the class then.
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
        let styles = project.editor.textStyles
        let on: [MenuCommand: Bool] = [.editBold: styles.bold != nil, .editItalic: styles.italic != nil,
                                       .editUnderline: styles.underline != nil]
        var items = [MenuCommand.editBold, .editItalic, .editUnderline].map { command in
            let item = self.item(command.title, #selector(apply(_:)), command)
            item.image = command.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            item.state = on[command] == true ? .on : .off
            return item
        }
        // Apart from the styles, which have symbols: a group has them for all its items or none (HIG, Menus).
        items += [.separator(), item(MenuCommand.editMath.title, #selector(apply(_:)), MenuCommand.editMath), .separator()]
        let headings = project.headingStyles, current = project.headingLevel
        for level in headings.levels {
            let item = self.item(level.title, #selector(choose(_:)), level)
            item.attributedTitle = NSAttributedString(string: level.title, attributes: [.font: Self.font(headings.font(level))])
            item.state = level == current ? .on : .off
            items.append(item)
        }
        let enabled = project.isLaTeX
        for item in items { item.isEnabled = enabled }
        menu.items = items
    }

    private func item(_ title: String, _ action: Selector, _ value: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    @objc private func apply(_ item: NSMenuItem) {
        if let command = item.representedObject as? MenuCommand { app.perform(command, on: project) }
    }

    @objc private func choose(_ item: NSMenuItem) {
        if let level = item.representedObject as? HeadingLevel { project.editor.perform(.heading, level.command) }
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
