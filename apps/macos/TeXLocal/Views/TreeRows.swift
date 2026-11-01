import AppKit
import SwiftUI

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

func disclosure(_ set: ReferenceWritableKeyPath<ProjectModel, Set<String>>, of project: ProjectModel, key: String,
                inverted: Bool = false, subtree: @autoclosure @escaping () -> [String] = []) -> Binding<Bool> {
    Binding(get: { project[keyPath: set].contains(key) != inverted },
            set: { on in
                let keys = NSEvent.modifierFlags.contains(.option) ? [key] + subtree() : [key]
                if on != inverted { project[keyPath: set].formUnion(keys) } else { project[keyPath: set].subtract(keys) }
            })
}
