import CoreMotion
import Foundation

/// Whether the boss is sitting still, walking, or driving.
///
/// `MotionTool` beside this answers *how much* he has moved; this answers what
/// he is doing **right now**, which is a different question and a more useful
/// one for deciding how to behave. Same free route: `CMMotionActivityManager`
/// needs only `NSMotionUsageDescription`, no capability the Personal Team cannot
/// sign (D-32).
///
/// **Queried, never subscribed.** `startActivityUpdates` would keep a callback
/// live for as long as the app runs; `queryActivityStarting` reads the motion
/// coprocessor's own log of the last few minutes and returns. Nothing runs
/// between questions, which is the same rule the sound listener follows and the
/// same reason: an assistant that watches you constantly is a different product
/// from one that answers when asked.
enum ActivityTool {

    /// What the phone thinks is happening, flattened to a value.
    ///
    /// `CMMotionActivity` is not `Sendable` and the handler is invoked on a
    /// queue of CoreMotion's choosing, so the object itself must not cross back
    /// — only this does. Third time this project has needed the same discipline,
    /// after `CNContact` and `CMPedometerData`.
    enum Doing: String, Sendable, Equatable {
        case still, walking, running, cycling, driving

        /// How FRIDAY says it.
        var spoken: String {
            switch self {
            case .still: "sitting still"
            case .walking: "walking"
            case .running: "running"
            case .cycling: "cycling"
            case .driving: "in a car"
            }
        }
    }

    /// How far back to look.
    ///
    /// The coprocessor logs continuously, so this costs nothing but a read. Two
    /// minutes is long enough to have caught the current activity and short
    /// enough that it is still the current one — asking about an hour would
    /// happily report the drive that ended forty minutes ago.
    private static let window: TimeInterval = 120

    /// What he's doing, or `nil` if the phone can't say.
    ///
    /// `nil` is a real answer and gets its own line. Motion is unavailable on
    /// some devices, the permission may be refused, and a phone lying on a desk
    /// while its owner walks around is genuinely unknowable — guessing "still"
    /// in any of those cases would be a fact invented to avoid saying "I don't
    /// know".
    static func current() async -> Doing? {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() != .denied,
              CMMotionActivityManager.authorizationStatus() != .restricted
        else { return nil }

        return await withCheckedContinuation { continuation in
            // Built per call rather than held. A `static let` manager does not
            // compile under strict concurrency — "non-Sendable type may have
            // shared mutable state" — and a local the compiler can prove is
            // uniquely owned removes the hazard instead of silencing it. Same
            // shape as `MotionTool`'s pedometer.
            let manager = CMMotionActivityManager()
            let queue = OperationQueue()

            manager.queryActivityStarting(
                from: Date().addingTimeInterval(-window),
                to: Date(),
                to: queue
            ) { activities, _ in
                // Mapped to `Doing` *here*, inside the callback, before anything
                // crosses back.
                let latest = activities?.last { $0.confidence != .low }
                continuation.resume(returning: latest.flatMap(classify))
                manager.stopActivityUpdates()
            }
        }
    }

    /// One activity reduced to one word.
    ///
    /// The flags are **not** mutually exclusive — CoreMotion will set `walking`
    /// and `automotive` together while you walk down a train carriage. Checked
    /// most-specific first so the more consequential reading wins: being in a
    /// car matters more to how FRIDAY should behave than the fact you shifted in
    /// your seat.
    private static func classify(_ activity: CMMotionActivity) -> Doing? {
        if activity.automotive { return .driving }
        if activity.cycling { return .cycling }
        if activity.running { return .running }
        if activity.walking { return .walking }
        if activity.stationary { return .still }
        return nil
    }

    /// Whether it's a bad moment to put a camera on screen.
    ///
    /// Bounded and fail-safe: any delay, refusal or unavailability answers
    /// **false**, so the camera still works exactly as it did before. A scanner
    /// that silently stopped opening because a motion query hung would be a far
    /// worse bug than the one this prevents.
    static func isDriving() async -> Bool {
        await withDeadline(seconds: 2) { await current() } == .driving
    }

    /// The line FRIDAY says when asked outright.
    static func sentence(for doing: Doing?) -> String {
        guard let doing else {
            return "Couldn't tell you, boss — the phone's not saying."
        }
        return "Looks like you're \(doing.spoken), boss."
    }
}
