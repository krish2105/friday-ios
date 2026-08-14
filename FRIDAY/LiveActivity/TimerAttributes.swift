import ActivityKit
import Foundation

/// Shape of the timer Live Activity.
///
/// ⚠️ TARGET MEMBERSHIP — this file must belong to **both** the FRIDAY app
/// target and the widget extension target, for the same reason as
/// `FridayAttributes`: the app writes the state, the extension renders it.
///
/// The deadline is `Codable` and fixed for the life of the activity, which is
/// what lets the countdown run with **zero updates**. `Text(timerInterval:)`
/// ticks in the system's own process — so a ten-minute timer costs exactly one
/// `Activity.request` and nothing else, where a per-second update would spend
/// the app's entire ActivityKit budget in under a minute and then stop.
struct TimerAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When it goes off. The countdown is derived, never pushed.
        var deadline: Date
    }

    /// What the timer is for, as FRIDAY would say it — "10 minutes".
    var label: String
}
