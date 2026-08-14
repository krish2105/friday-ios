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
    private var activity: Activity<FridayAttributes>?

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
        guard let activity else { return }
        self.activity = nil
        await activity.end(nil, dismissalPolicy: .immediate)
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
