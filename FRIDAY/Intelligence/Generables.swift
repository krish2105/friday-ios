import FoundationModels

/// A reply from FRIDAY, produced by guided generation.
///
/// Guided generation constrains the model at the token level, so this arrives
/// as a typed value rather than a string that needs parsing.
@Generable
struct FridayReply {
    @Guide(description: "What FRIDAY says aloud. Under 3 sentences. Spoken register, not written.")
    let spoken: String

    @Guide(description: "Mood in one word: calm, alert, amused, or concerned")
    let tone: String
}
