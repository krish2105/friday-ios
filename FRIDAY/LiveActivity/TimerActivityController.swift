import ActivityKit
import Foundation
import Observation

/// Puts a running timer in the Dynamic Island and on the Lock Screen.
///
/// This is the Live Activity the app actually wanted. HANDOVER §8 records that
/// the state activity is "close to unobservable" because FRIDAY's states last
/// seconds — you cannot watch something that has finished by the time you have
/// looked down. A timer lasts minutes by definition, which is the shape a Live
/// Activity is for.
///
/// Best-effort throughout, like `LiveActivityController`. Activities can be
/// disabled system-wide or per-app, and nothing here is load-bearing: the
/// notification still fires either way, because that is what actually tells him
/// the time is up.
@MainActor
@Observable
final class TimerActivityController {
    // Same escape hatch, and the same reasoning as `LiveActivityController`:
    // `Activity` is non-Sendable with nonisolated async methods, and
    // `@ObservationIgnored` is load-bearing because the macro would otherwise
    // rewrite this into a computed property that cannot carry the attribute.
    @ObservationIgnored nonisolated(unsafe) private var activity: Activity<TimerAttributes>?

    private var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Starts a countdown ending at `deadline`.
    ///
    /// Only one at a time: a second timer replaces the first rather than
    /// stacking, because two countdowns in the Island with no way to tell them
    /// apart is worse than one.
    func start(label: String, deadline: Date) {
        guard isEnabled, deadline > Date() else { return }

        Task { await end() }

        do {
            activity = try Activity.request(
                attributes: TimerAttributes(label: label),
                content: ActivityContent(
                    state: TimerAttributes.ContentState(deadline: deadline),
                    // Dismissed by the system shortly after it fires. Without
                    // this a finished timer sits on the Lock Screen until it is
                    // swiped away, which reads as a bug rather than a record.
                    staleDate: deadline.addingTimeInterval(60)
                )
            )
        } catch {
            activity = nil
        }
    }

    func end() async {
        // Straight on the property, never via a local — the same trap
        // `LiveActivityController.end()` already documents. A local bound in
        // this `@MainActor` method takes the main actor's region and cannot be
        // sent to `end`, which is nonisolated; a direct access on the
        // `nonisolated(unsafe)` property can. The `guard let` form was written
        // here first and does not compile, which is a lesson this project had
        // already paid for once.
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }
}
