import UIKit

/// Three distinct sensations, one per moment that matters.
///
/// Deliberately not used for anything else — haptics stop meaning anything if
/// every interaction buzzes.
@MainActor
enum Haptics {
    /// A turn has begun. Firm and unmistakable through a pocket.
    static func listeningStarted() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    /// FRIDAY has answered.
    static func replyReceived() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Something failed.
    static func failed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
