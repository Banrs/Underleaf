#if os(macOS)
import AppKit
#endif
import SwiftUI

/// A tree's rows, folders and headings as disclosure groups whose open state the project keeps with its settings.
struct TreeRows<Node: Identifiable, Row: View>: View {
    let nodes: [Node]
    let children: (Node) -> [Node]?
    let isExpanded: (Node) -> Binding<Bool>
    var insert: (([URL]) -> Void)?
    @ViewBuilder let row: (Node) -> Row

    var body: some View {
        let rows = ForEach(nodes) { node in
            if let kids = children(node) {
                DisclosureGroup(isExpanded: isExpanded(node)) {
                    TreeRows(nodes: kids, children: children, isExpanded: isExpanded, row: row)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
        if let insert {
            rows.dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                if !files.isEmpty { insert(files) }
            }
        } else {
            rows
        }
    }
}

/// Not a `Binding` of the set: two changes in one click would each start from the set as it was. On the Mac, Option takes
/// the `subtree`'s keys with it (HIG, Outline views).
func disclosure(_ set: ReferenceWritableKeyPath<ProjectModel, Set<String>>, of project: ProjectModel, key: String,
                inverted: Bool = false, subtree: @autoclosure @escaping () -> [String] = []) -> Binding<Bool> {
    Binding(get: { project[keyPath: set].contains(key) != inverted },
            set: { on in
                #if os(macOS)
                let keys = NSEvent.modifierFlags.contains(.option) ? [key] + subtree() : [key]
                #else
                let keys = [key]
                #endif
                if on != inverted { project[keyPath: set].formUnion(keys) } else { project[keyPath: set].subtract(keys) }
            })
}
