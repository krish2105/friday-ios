import ActivityKit
import Observation

/// Starts, updates and ends the Live Activity as FRIDAY changes state.
///
/// Every call is best-effort. Live Activities can be disabled system-wide or
/// per-app, and none of this is load-bearing — if it silently does nothing, the
/// app still works exactly as before.
@MainActor
@Observable
final class LiveActivityController {
    // `Activity` is a non-Sendable class whose `update` and `end` are
    // *nonisolated* async methods. Held in MainActor-isolated storage, passing
    // it to them means sending a non-Sendable value across isolation domains,
    // which Swift 6 rejects.
    //
    // `@ObservationIgnored` is load-bearing, not decoration: without it the
    // `@Observable` macro rewrites this into an `@ObservationTracked` computed
    // property, and an isolation attribute cannot be applied to that at all
    // ("'nonisolated' cannot be applied to mutable stored properties", raised
    // against the macro expansion). Nothing observes this property — it is
    // private plumbing — so opting it out of tracking costs nothing.
    //
    // `nonisolated(unsafe)` is then safe because the class is @MainActor: every
    // read and write below is already serialised on the main actor, so there is
    // no concurrent access for the attribute to hide.
    @ObservationIgnored nonisolated(unsafe) private var activity: Activity<FridayAttributes>?

    private var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Single entry point, driven by the engine's state.
    func sync(state: FridayState, snippet: String) {
        guard isEnabled else { return }

        guard let status = Self.status(for: state) else {
            // Back to rest — nothing worth occupying the Island.
            Task { await end() }
            return
        }

        let content = FridayAttributes.ContentState(
            status: status,
            snippet: String(snippet.prefix(120))
        )

        if activity == nil {
            start(with: content)
        } else {
            Task { await update(content) }
        }
    }

    // MARK: - Lifecycle

    private func start(with content: FridayAttributes.ContentState) {
        do {
            activity = try Activity.request(
                attributes: FridayAttributes(title: "FRIDAY"),
                content: ActivityContent(state: content, staleDate: nil),
                pushType: nil
            )
        } catch {
            // Rate limited, disabled mid-flight, or too many activities.
            activity = nil
        }
    }

    private func update(_ content: FridayAttributes.ContentState) async {
        await activity?.update(ActivityContent(state: content, staleDate: nil))
    }

    func end() async {
        // Called straight on the property, not via a local. A local bound
        // inside this @MainActor method takes the main actor's region and
        // cannot be sent to `end`, which is nonisolated; a direct access on the
        // nonisolated(unsafe) property can. Verified both ways against the
        // compiler — the local form does not build.
        //
        // Clearing after the await is also the safer order. Clearing first
        // would let a `sync` landing during the suspension see nil and request
        // a second activity while this one is still ending.
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }

    /// `nil` means "not worth showing" — idle and error both fall through.
    private static func status(for state: FridayState) -> String? {
        switch state {
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .idle, .error: nil
        }
    }
}
