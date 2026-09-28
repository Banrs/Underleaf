import AppKit
import XCTest
@testable import TeXLocal

/// Settings › General › Appearance, as windows and popovers take it.
@MainActor
final class AppearanceTests: XCTestCase {
    override func tearDown() async throws {
        AppAppearance.saved.apply()
    }

    private func shown(_ view: NSView) -> NSAppearance.Name? {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }

    func testTheChoiceReachesWindowsAndPopovers() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let anchor = try XCTUnwrap(window.contentView)
        let popover = NSPopover()
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        popover.contentViewController = content

        for (choice, expected) in [(AppAppearance.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            choice.apply()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            XCTAssertEqual(shown(anchor), expected, choice.rawValue)
            XCTAssertEqual(shown(content.view), expected, choice.rawValue)
            popover.close()
        }
        AppAppearance.system.apply()
        XCTAssertNil(NSApp.appearance)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        let system = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        XCTAssertEqual(shown(anchor), system)
        XCTAssertEqual(shown(content.view), system)
        popover.close()
    }
}
