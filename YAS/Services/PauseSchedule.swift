import Foundation
import YASShared

/// Pure rules for "Pause filtering": what mode applies at launch
/// given the persisted deadline, and how to describe the time left.
enum PauseSchedule {
    struct State: Equatable, Sendable {
        let mode: FilterMode
        /// Still paused until this date; nil when not paused.
        let pausedUntil: Date?
        let modeBeforePause: FilterMode?
    }

    /// State to apply at launch. If the deadline passed while the app was quit,
    /// the pre-pause mode comes back; an incomplete record is discarded.
    static func restore(savedMode: FilterMode, pausedUntil: Date?, modeBeforePause: FilterMode?, now: Date) -> State {
        guard let pausedUntil, let modeBeforePause else {
            return State(mode: savedMode, pausedUntil: nil, modeBeforePause: nil)
        }
        if pausedUntil <= now {
            return State(mode: modeBeforePause, pausedUntil: nil, modeBeforePause: nil)
        }
        return State(mode: .allowAll, pausedUntil: pausedUntil, modeBeforePause: modeBeforePause)
    }

    /// Whole minutes left, rounded up (so "resumes in 1 min" until the end), at least 1.
    static func minutesRemaining(until deadline: Date, now: Date) -> Int {
        max(1, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
    }
}
