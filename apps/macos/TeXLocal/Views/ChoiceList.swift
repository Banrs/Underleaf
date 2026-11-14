import AppKit
import SwiftUI

class FloatingPanel: NSPanel {
    private let takesKeys: Bool

    init(takesKeys: Bool) {
        self.takesKeys = takesKeys
        super.init(contentRect: .zero, styleMask: takesKeys ? [.borderless] : [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { takesKeys }

    func show(_ frame: NSRect, over window: NSWindow, animated: Bool) {
        let opening = parent == nil
        guard opening || frame != self.frame else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animates = !opening && animated && !reduceMotion
        // A zero-length group also stops a resize still running, even one from before the panel last closed, which a plain
        // setFrame would leave to finish.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animates ? animationResizeTime(frame) : 0
            animator().setFrame(frame, display: !opening)
        }
        guard opening else { return }
        alphaValue = reduceMotion ? 1 : 0
        window.addChildWindow(self, ordered: .above)
        if !reduceMotion { NSAnimationContext.runAnimationGroup { _ in animator().alphaValue = 1 } }
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

struct ChoiceList<Item, Row: View>: View {

    let rows: ChoiceRows<Item>
    let height: CGFloat
    let corner: CGFloat
    let truncation: Text.TruncationMode
    let chosen: (Int) -> Void
    @ViewBuilder let row: (Item) -> Row

    private static var text: Color { Color(nsColor: .labelColor) }
    private static var chosenText: Color { Color(nsColor: .alternateSelectedControlTextColor) }
    private static var accent: Color { Color(nsColor: .controlAccentColor) }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows.items.indices, id: \.self) { index in
                        let selected = index == rows.selection
                        row(rows.items[index])
                            .lineLimit(1)
                            .truncationMode(truncation)
                            .foregroundStyle(selected ? Self.chosenText : Self.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, CompletionRowsView.textInset)
                            .frame(height: height)
                            .background(selected ? Self.accent : .clear, in: .rect(cornerRadius: corner - CompletionRowsView.margin))
                            .padding(.horizontal, CompletionRowsView.margin)
                            .contentShape(.rect)
                            .onTapGesture { chosen(index) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { chosen(index) }
                            .id(index)
                    }
                }
            }
            .scrollIndicators(.never)
            .padding(.vertical, CompletionRowsView.margin)
            .onChange(of: rows.revealed) { scroller.scrollTo(rows.selection) }
        }
    }
}

@Observable final class ChoiceRows<Item> {
    var items: [Item] = [] { didSet { selection = 0; reveal() } }
    var selection = 0
    private(set) var revealed = 0
    @ObservationIgnored private let spoken: (Item) -> [String?]

    init(spoken: @escaping (Item) -> [String?]) { self.spoken = spoken }

    func reveal() { revealed += 1 }

    func move(_ step: Int) {
        selection = max(0, min(items.count - 1, selection + step))
        reveal()
        announce()
    }

    func announce(interrupting: Bool = true) {
        guard items.indices.contains(selection) else { return }
        let words = spoken(items[selection]).compactMap(\.self) + [String(localized: "\(selection + 1) of \(items.count)")]
        var announcement = AttributedString(words.formatted(.list(type: .and, width: .narrow)))
        announcement.accessibilitySpeechAnnouncementPriority = interrupting ? .high : .low
        AccessibilityNotification.Announcement(announcement).post()
    }
}
