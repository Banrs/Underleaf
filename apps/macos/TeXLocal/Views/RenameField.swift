import SwiftUI

@Observable
final class InPlaceRename<ID: Hashable> {
    private(set) var id: ID?
    var name = ""

    func begin(_ id: ID, name: String) {
        self.name = name
        self.id = id
    }

    func cancel() { id = nil }

    func end(_ id: ID, from old: String) -> String? {
        guard self.id == id else { return nil }
        self.id = nil
        let new = name.trimmingCharacters(in: .whitespaces)
        return new.isEmpty || new == old ? nil : new
    }
}

struct RenameField: View {
    @Binding var text: String
    var isFile = false
    var forbidden: Character?
    var spaceWarning: LocalizedStringKey?
    let ended, commit, cancel: () -> Void
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Name", text: $text, selection: $selection)
                .labelsHidden()
                .focused($focused)
                .onExitCommand { cancel(); ended() }
                .onSubmit { commit(); ended() }
                .onChange(of: text) { _, new in
                    if let forbidden, new.contains(forbidden) {
                        text = new.filter { $0 != forbidden }
                        NSSound.beep()
                    }
                }
                .onChange(of: focused) { was, now in
                    if now, isFile { selection = .baseName(of: text) }
                    if was, !now { commit() }
                }
                .onAppear { focused = true }
            if let spaceWarning, text.contains(" ") {
                Text(spaceWarning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension TextSelection {
    static func baseName(of name: String) -> TextSelection {
        let dot = name.lastIndex(of: ".").flatMap { $0 > name.startIndex ? $0 : nil }
        return TextSelection(range: name.startIndex..<(dot ?? name.endIndex))
    }
}
