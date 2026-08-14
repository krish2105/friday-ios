import Foundation

/// Guarantees exactly one resume of a continuation — resuming twice is a crash.
private actor ResumeGate {
    private var taken = false

    func claim() -> Bool {
        defer { taken = true }
        return !taken
    }
}

/// Runs `work`, giving up on it after `seconds`.
///
/// Every long operation in this app has to be bounded, and the reason is
/// HANDOVER §7: the talk button only acts when `state == .idle`, so anything
/// that strands the engine in `.thinking` leaves an app that cannot be used
/// until it is relaunched. A dead app is the failure, not the slow operation.
///
/// The loser is **abandoned rather than awaited**, which is the same choice
/// `FridayEngine.respondWithDeadline` made and for the same reason: a task group
/// awaits every child, so a child parked in an unresumed continuation would keep
/// the group — and the deadline — waiting forever. A stranded task is a small
/// leak; a stranded `.thinking` is a dead app.
///
/// Returns `nil` when the deadline wins.
func withDeadline<T: Sendable>(
    seconds: Int,
    _ work: @escaping @Sendable () async -> T?
) async -> T? {
    let gate = ResumeGate()

    return await withCheckedContinuation { continuation in
        Task {
            let value = await work()
            if await gate.claim() { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if await gate.claim() { continuation.resume(returning: nil) }
        }
    }
}
