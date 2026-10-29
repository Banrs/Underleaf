import Foundation

nonisolated extension Menus {
    static let shared = Syntax.call(ListMenus()) ?? Menus(templates: Templates(math: [], insert: [], list: [], references: []), symbolGroups: [])
}

extension ProjectModel {
    func insert(_ template: Template) {
        views?.perform(template.inline ? .inline(template: template.body, title: template.title)
                                       : .block(id: template.body, title: template.title))
    }
}

nonisolated extension HeadingStyle {
    static let standard = Syntax.call(HeadingStyles()) ?? []
}
