import AppKit
import Testing
@testable import TeXLocal

/// Settings › General › Appearance, as windows and popovers take it.
@MainActor
struct AppearanceTests {
    private func shown(_ view: NSView) -> NSAppearance.Name? {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }

    @Test func theChoiceReachesWindowsAndPopovers() throws {
        defer { AppAppearance.saved.apply() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let anchor = try #require(window.contentView)
        let popover = NSPopover()
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        popover.contentViewController = content

        for (choice, expected) in [(AppAppearance.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            choice.apply()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            #expect(shown(anchor) == expected, "\(choice.rawValue)")
            #expect(shown(content.view) == expected, "\(choice.rawValue)")
            popover.close()
        }
        AppAppearance.system.apply()
        #expect(NSApp.appearance == nil)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        let system = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        #expect(shown(anchor) == system)
        #expect(shown(content.view) == system)
        popover.close()
    }
}
