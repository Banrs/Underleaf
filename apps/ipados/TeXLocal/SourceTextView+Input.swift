import UIKit
import UniformTypeIdentifiers

/// The keys and touches the text view adds to UIKit's: the shortcuts bar's LaTeX keys, Escape and Shift-Tab, the
/// completion list's arrows, a double tap's PDF position, ⌘-tap's definition, file drops and VoiceOver's rotors.
extension SourceTextView {
    func installInput() {
        // Smart dashes and quotes, corrections and predictions would rewrite the LaTeX; Writing Tools keep to the prose, and
        // spelling is the view's own (+Spelling), as UIKit's would check the TeX too.
        autocorrectionType = .no
        spellCheckingType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        mathExpressionCompletionType = .no
        dataDetectorTypes = []
        writingToolsBehavior = .limited
        allowedWritingToolsResultOptions = .plainText
        isFindInteractionEnabled = true
        // A swipe down the text takes the keyboard down with it, as in Notes.
        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        backgroundColor = .editorBackground
        accessibilityLabel = String(localized: "Source")
        textDropDelegate = self
        installShortcutsBar()
        let sync = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        sync.numberOfTapsRequired = 2
        sync.cancelsTouchesInView = false
        sync.delaysTouchesEnded = false
        sync.delegate = gestures
        addGestureRecognizer(sync)
        let jump = UITapGestureRecognizer(target: self, action: #selector(commandTapped))
        jump.delegate = gestures
        addGestureRecognizer(jump)
        gestures.jump = jump
        gestures.definition = { [unowned self] point in definitionPlace(at: point) }
    }

    /// The keys LaTeX needs that the iPad's keyboard has only on its symbols' layer, and those a hardware keyboard has: Tab
    /// (which also takes a completion, and goes to a snippet's next field), the completion list, and Escape.
    private func installShortcutsBar() {
        let characters: [(String, String)] = [
            ("\\", String(localized: "Backslash")), ("{", String(localized: "Left Brace")), ("}", String(localized: "Right Brace")),
            ("$", String(localized: "Dollar Sign")), ("^", String(localized: "Caret")), ("_", String(localized: "Underscore")),
        ]
        let keys = characters.map { text, name in
            let key = UIBarButtonItem(title: text, primaryAction: UIAction { [unowned self] _ in insertText(text) })
            key.accessibilityLabel = name
            return key
        }
        func key(_ symbol: String, _ name: String, _ action: @escaping () -> Void) -> UIBarButtonItem {
            let key = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in action() })
            key.accessibilityLabel = name
            return key
        }
        let commands = [
            key("arrow.right.to.line", String(localized: "Tab")) { [unowned self] in insertText("\t") },
            key("text.badge.plus", String(localized: "Show Completions")) { [unowned self] in completions.complete(explicit: true) },
            key("escape", String(localized: "Escape")) { [unowned self] in cancel() },
        ]
        // Folded behind one key where the bar is short of room, as in a narrow window.
        let folded = UIBarButtonItem(image: UIImage(systemName: "curlybraces"))
        folded.accessibilityLabel = String(localized: "LaTeX Characters")
        inputAssistantItem.trailingBarButtonGroups = [
            UIBarButtonItemGroup(barButtonItems: keys, representativeItem: folded),
            UIBarButtonItemGroup(barButtonItems: commands, representativeItem: nil),
        ]
    }

    // MARK: a hardware keyboard's keys

    override var keyCommands: [UIKeyCommand]? {
        var ours = [UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(backtab)),
                    UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
                    // The Mac's key for completions.
                    UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: .alternate, action: #selector(showCompletions))]
        // While the list shows, the arrows move through it; Return and Tab come as typing (`insertText`).
        if completions.offered != nil {
            ours += [UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previousCompletion)),
                     UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextCompletion))]
        }
        ours.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + ours
    }

    @objc private func backtab() { if isEditable { tab(-1) } }
    @objc private func escape() { cancel() }
    @objc private func showCompletions() { completions.complete(explicit: true) }
    @objc private func previousCompletion() { completions.move(-1) }
    @objc private func nextCompletion() { completions.move(1) }

    // MARK: touches

    /// A double tap selects the word, and shows where it is in the PDF, as a double-click does on the Mac.
    @objc private func doubleTapped() { forwardSync(true)?() }

    @objc private func commandTapped(_ recognizer: UITapGestureRecognizer) {
        definitionPlace(at: recognizer.location(in: self)).map(openDefinition)
    }

    private func definitionPlace(at point: CGPoint) -> Definition.Place? {
        guard let position = closestPosition(to: point) else { return nil }
        return document.definition(at: offset(from: beginningOfDocument, to: position))?.places.first
    }

    // MARK: VoiceOver's rotors

    override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get {
            [UIAccessibilityCustomRotor(systemType: .heading) { [weak self] in self?.rotorResult(issues: false, $0) },
             UIAccessibilityCustomRotor(name: String(localized: "Issues")) { [weak self] in self?.rotorResult(issues: true, $0) }]
        }
        set {}
    }

    private func rotorResult(issues listed: Bool, _ search: UIAccessibilityCustomRotorSearchPredicate) -> UIAccessibilityCustomRotorItemResult? {
        let current = search.currentItem.targetRange.map { document.line(at: min(offset(from: beginningOfDocument, to: $0.start), length)) }
        guard let found = rotorItem(issues: listed, from: current, next: search.searchDirection == .next),
              let range = uiRange(found.range) else { return nil }
        // A rotor's item is spoken as its text, so an issue's words are said too.
        if listed { UIAccessibility.post(notification: .announcement, argument: found.title) }
        return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: range)
    }
}

/// A double tap keeps the text view's own, and ⌘-tap goes before the tap that would place the caret.
final class EditorGestures: NSObject, UIGestureRecognizerDelegate {
    weak var jump: UIGestureRecognizer?
    var definition: (CGPoint) -> Definition.Place? = { _ in nil }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === jump else { return true }
        return recognizer.modifierFlags.contains(.command) && definition(recognizer.location(in: recognizer.view)) != nil
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        recognizer !== jump
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        recognizer === jump && other is UITapGestureRecognizer && other.view === recognizer.view && other !== recognizer
    }
}

// MARK: file drops open, or insert a figure

extension SourceTextView: UITextDropDelegate {
    /// A file from the project's own list, or one Files opens in place; else what UIKit makes of the text.
    private func isFileDrop(_ session: any UIDropSession) -> Bool {
        session.items.contains {
            $0.localObject is URL || $0.itemProvider.hasRepresentationConforming(toTypeIdentifier: UTType.item.identifier, fileOptions: [.openInPlace])
        }
    }

    func textDroppableView(_ view: any UIView & UITextDroppable, proposalForDrop drop: any UITextDropRequest) -> UITextDropProposal {
        guard isFileDrop(drop.dropSession) else { return drop.suggestedProposal }
        // The project's own files are known at once: those it can't take are refused as they're dragged.
        let local = drop.dropSession.items.compactMap { $0.localObject as? URL }
        if !local.isEmpty {
            switch local.lazy.compactMap(fileDrop).first {
            case nil: return UITextDropProposal(operation: .forbidden)
            case .insert?: if !isEditable { return UITextDropProposal(operation: .forbidden) }
            case .open?: break
            }
        }
        let proposal = UITextDropProposal(operation: .copy)
        proposal.dropPerformer = .delegate
        return proposal
    }

    func textDroppableView(_ view: any UIView & UITextDroppable, willPerformDrop drop: any UITextDropRequest) {
        guard isFileDrop(drop.dropSession) else { return }
        let at = offset(from: beginningOfDocument, to: drop.dropPosition)
        let items = drop.dropSession.items
        Task {
            for item in items {
                guard let url = await Self.url(of: item), let found = fileDrop(url) else { continue }
                return dropped(found, at: at)
            }
        }
    }

    private func dropped(_ drop: FileDrop, at: Int) {
        switch drop {
        case .open(let open): open()
        case .insert(let text):
            guard isEditable else { return }
            apply([TextEdit(.caret(at), text)], named: String(localized: "Insert Figure"),
                  selecting: [NSRange(location: at, length: (text as NSString).length)])
            _ = becomeFirstResponder()
        }
    }

    private static func url(of item: UIDragItem) async -> URL? {
        if let url = item.localObject as? URL { return url }
        return await withCheckedContinuation { done in
            _ = item.itemProvider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, inPlace, _ in
                done.resume(returning: inPlace ? url : nil)
            }
        }
    }
}
