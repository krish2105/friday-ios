import Foundation
import NaturalLanguage

/// Reading something in a language you don't have.
///
/// Every piece of this already existed and none of it was joined up: `TextScanner`
/// pulls words off a photograph, `Translator` moves words between languages, and
/// until now the two had never met. Point the camera at a Hindi menu and FRIDAY
/// would read it back to you *in Hindi*, which is a party trick rather than help.
///
/// **Detection is measured, not assumed.** `NLLanguageRecognizer` was rejected
/// earlier in this project for routing romanised Hindi — "kitna baja hai" came
/// back Dutch, Indonesian and Finnish across three tries. That verdict stands for
/// what it tested and does not transfer here, because this is a different problem:
/// a scanned page is *native script*, and long. Measured on eight page-length
/// samples (Hindi menu and sign, French, Spanish, German, Japanese, Italian,
/// English receipt) it was **8/8**, with confidence ≥ 0.998 on every non-English
/// case.
///
/// The English receipt scored **0.561**, which is the whole reason
/// `confidenceFloor` exists. Latin-script European languages share enough
/// vocabulary that a short till receipt is genuinely ambiguous, and a confident
/// wrong guess would translate an English receipt *out of* English.
enum SightTranslator {

    /// Below this, the guess isn't worth acting on.
    ///
    /// Set from the measurement above rather than picked: every correct
    /// non-English detection cleared 0.998, and the one genuinely ambiguous
    /// sample — an English receipt of six short lines — sat at 0.561. Anything
    /// under this earns "I can't tell what that's in" instead of a translation
    /// nobody can check.
    static let confidenceFloor: Double = 0.75

    /// What the page turned out to be, and what can be done about it.
    enum Reading: Equatable {
        /// Detected, supported, and different from the target.
        case translatable(from: String, to: String)
        /// It's already in the language he wanted it in.
        case alreadyThere(language: String)
        /// Detected, but Apple's translator has no pack for it.
        case unsupported(language: String)
        /// Not enough signal to say. Short receipts and menus of bare numbers
        /// land here, and so does a page that is mostly a photograph.
        case unknown
    }

    /// What language the page is in, and whether that's worth translating.
    ///
    /// `target` is the language he wants it *in*, so a page already in that
    /// language is reported rather than round-tripped — translating English to
    /// English costs a pack, a second, and a slightly worse sentence.
    static func reading(of text: String, into target: String) -> Reading {
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(text)

        guard let dominant = recogniser.dominantLanguage,
              let confidence = recogniser.languageHypotheses(withMaximum: 1)[dominant],
              confidence >= confidenceFloor
        else { return .unknown }

        // `NLLanguage` carries script and region for some languages —
        // `zh-Hans` rather than `zh` — and `Tongues` is keyed on base codes, so
        // this is collapsed the same way `Tongues` collapses its own list.
        let source = String(dominant.rawValue.prefix(while: { $0 != "-" }))

        guard source != target else { return .alreadyThere(language: source) }
        guard Tongues.isSupported(source) else { return .unsupported(language: source) }
        return .translatable(from: source, to: target)
    }

    /// How much of a page is worth translating in one go.
    ///
    /// A menu is a page; a contract is forty. D-61 says bound anything whose
    /// length the app does not choose, and this is the same rule one layer
    /// earlier — the cap is on the work, not just the view. 4,000 characters is
    /// several times a restaurant menu and still returns inside the deadline.
    static let characterCap = 4_000

    static func capped(_ text: String) -> String {
        guard text.count > characterCap else { return text }
        return String(text.prefix(characterCap))
    }

    /// The line FRIDAY says when she can't do it, in her register.
    ///
    /// Composed in Swift, so each case names *why* and what would fix it —
    /// "I couldn't do that" is the failure mode this project keeps designing out.
    static func sentence(for reading: Reading, wasCapped: Bool = false) -> String {
        switch reading {
        case .alreadyThere(let language):
            "That's already in \(Tongues.name(for: language)), boss."

        case .unsupported(let language):
            "That looks like \(Tongues.name(for: language)), boss, and I've no pack for it."

        case .unknown:
            "I can't tell what that's written in, boss. Try a clearer shot, or more of the page."

        case .translatable(let from, _):
            wasCapped
                ? "That's \(Tongues.name(for: from)), boss — here's the first of it."
                : "That's \(Tongues.name(for: from)), boss."
        }
    }
}
