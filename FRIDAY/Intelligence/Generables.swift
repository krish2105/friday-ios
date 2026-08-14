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

/// What a receipt says, pulled out of recognised text by guided generation.
///
/// Every field is asked for **verbatim**, and that is the whole design rather
/// than a wording preference. The model's job here is *selection*, not
/// composition: it points at a run of characters that is already in the page,
/// and `ReceiptReader` then checks the run is really there before FRIDAY says
/// it aloud.
///
/// D-44 exists because a ~3B model paraphrasing a number can quietly change it,
/// and that is the worst failure an assistant has. Reading money off a document
/// is that same risk with the stakes raised — "TOTAL 47.30" coming back as 43.70
/// is a confidently wrong answer about the boss's money. Asking for a copy is
/// what makes the claim checkable; checking it is what makes it safe.
///
/// A field that is not printed comes back empty rather than guessed, because a
/// missing merchant should cost the merchant, not the total.
@Generable
struct Receipt {
    @Guide(description: "The shop or business name, copied exactly as printed. Empty if not printed.")
    let merchant: String

    @Guide(description: "The date, copied exactly as printed. Do not reformat it. Empty if not printed.")
    let date: String

    @Guide(description: "The grand total paid, with its currency symbol, copied exactly as printed. Never add anything up.")
    let total: String
}
