import Foundation

/// One side of the conversation.
struct ConversationTurn: Identifiable, Sendable {
    enum Speaker: Sendable {
        case boss
        case friday
    }

    /// What a turn *is*, which is not always someone speaking.
    ///
    /// Recognised text from a page used to render identically to FRIDAY talking,
    /// and that was wrong twice over: it is not her voice, and since D-61 it may
    /// be a truncated excerpt. A quotation should look like one.
    enum Kind: Sendable {
        case speech
        case quoted
    }

    let id = UUID()
    let speaker: Speaker
    var text: String
    /// FRIDAY's mood for this turn, from the model. `nil` for the boss.
    var tone: String?
    var kind: Kind = .speech

    var isFriday: Bool { speaker == .friday }
}
