import FoundationModels

/// A reply from FRIDAY, produced by guided generation.
///
/// Guided generation constrains the model at the token level, so this arrives
/// as a typed value rather than a string that needs parsing.
@Generable
struct FridayReply {
    // The "boss" requirement lives here, not only in the persona. Guided
    // generation constrains this field directly, so a rule stated here steers
    // the 3B model far more reliably than the same rule in the instructions,
    // where it competes with five tool schemas for a ~4,096 token budget.
    // On device, the persona alone was not enough — replies came back as
    // "I'm here and ready to assist" with no form of address at all.
    @Guide(description: "What FRIDAY says aloud, addressing Krishna as \"boss\" — for example \"On it, boss.\" Under 3 sentences. Spoken register, not written.")
    let spoken: String

    @Guide(description: "Mood in one word: calm, alert, amused, or concerned")
    let tone: String
}
