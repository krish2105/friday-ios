import Foundation

/// One side of the conversation.
struct ConversationTurn: Identifiable, Sendable {
    enum Speaker: Sendable {
        case boss
        case friday
    }

    let id = UUID()
    let speaker: Speaker
    var text: String
    /// FRIDAY's mood for this turn, from the model. `nil` for the boss.
    var tone: String?

    var isFriday: Bool { speaker == .friday }
}
