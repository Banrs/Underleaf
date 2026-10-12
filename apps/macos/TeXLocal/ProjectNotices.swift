import Accessibility
import Foundation
import Observation

/// What a project has to say that interrupts nothing: the status bar's notice, and what VoiceOver
/// is told, which share the one record of what was last said.
@Observable
final class ProjectNotices {
    /// News that interrupts nothing, in the status bar for a few seconds and spoken by VoiceOver.
    private(set) var current: String?
    @ObservationIgnored private var clearing: Task<Void, Never>?

    func note(_ text: String) {
        current = text
        announce(text)
        clearing?.cancel()
        clearing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.current = nil }
        }
    }

    @ObservationIgnored private var announced: (text: String, at: ContinuousClock.Instant)?

    /// Not within 0.3 s of the last announcement, nor the same one again within a few seconds:
    /// VoiceOver would cut one short or repeat itself. `queued`, it waits for what VoiceOver is
    /// saying instead of interrupting it.
    func announce(_ text: String, queued: Bool = false) {
        let now = ContinuousClock.now
        if let announced, now - announced.at < (text == announced.text ? .seconds(3) : .milliseconds(300)) { return }
        announced = (text, now)
        var speech = AttributedString(text)
        if queued { speech.accessibilitySpeechAnnouncementPriority = .low }
        AccessibilityNotification.Announcement(speech).post()
    }

    /// The project closed: nothing waits to clear its notice.
    func cancel() {
        clearing?.cancel()
    }
}
