import Accessibility
import Foundation
import Observation

@Observable
final class ProjectNotices {
    private(set) var current: String?
    @ObservationIgnored private var clearing: Task<Void, Never>?
    @ObservationIgnored private let lasting: Duration

    init(lasting: Duration = .seconds(3)) { self.lasting = lasting }

    func note(_ text: String) {
        current = text
        announce(text)
        restart(&clearing, after: lasting) { [weak self] in self?.current = nil }
    }

    @ObservationIgnored private var announced: (text: String, at: ContinuousClock.Instant)?

    /// Not within 0.3 s of the last announcement, nor the same one again within a few seconds: VoiceOver would cut one short or repeat itself.
    func announce(_ text: String, queued: Bool = false) {
        let now = ContinuousClock.now
        if let announced, now - announced.at < (text == announced.text ? .seconds(3) : .milliseconds(300)) { return }
        announced = (text, now)
        var speech = AttributedString(text)
        if queued { speech.accessibilitySpeechAnnouncementPriority = .low }
        AccessibilityNotification.Announcement(speech).post()
    }

    func cancel() {
        clearing?.cancel()
    }
}
