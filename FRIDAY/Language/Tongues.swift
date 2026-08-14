import Foundation

/// The languages Apple's translator can handle, by the names people say.
///
/// The list is not invented: it is the 38 identifiers
/// `LanguageAvailability.supportedLanguages` returned on 2026-08-15, collapsed
/// to their base languages. Regional variants are dropped on purpose — nobody
/// asks for "Brazilian Portuguese", they ask for Portuguese, and the framework
/// picks a variant perfectly well on its own.
///
/// Aliases are here because a name is what someone *says*, not what a standard
/// calls it. "Mandarin" is Chinese, "Castilian" is Spanish, and a Hindi speaker
/// may well say "Hindustani".
enum Tongues {

    private static let byName: [String: String] = [
        "arabic": "ar",
        "danish": "da",
        "german": "de", "deutsch": "de",
        "english": "en",
        "spanish": "es", "castilian": "es",
        "french": "fr",
        "hindi": "hi", "hindustani": "hi",
        "indonesian": "id", "bahasa": "id",
        "italian": "it",
        "japanese": "ja",
        "korean": "ko",
        "norwegian": "nb",
        "dutch": "nl",
        "polish": "pl",
        "portuguese": "pt",
        "russian": "ru",
        "swedish": "sv",
        "thai": "th",
        "turkish": "tr",
        "ukrainian": "uk",
        "vietnamese": "vi",
        "chinese": "zh", "mandarin": "zh"
    ]

    /// Names longest-first, so "chinese" is tried before "hindi" can match
    /// inside a longer word and a two-word name is never half-matched.
    private static let namesByLength: [String] = byName.keys.sorted { $0.count > $1.count }

    /// The language code for a spoken name, or `nil` if it is not one.
    ///
    /// Returning `nil` for an unknown word is what stops "what's the time in
    /// London" being read as a translation request — the gate is that the word
    /// after "in" has to actually be a language.
    static func code(named name: String) -> String? {
        byName[name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// The first language named anywhere in a phrase, with what preceded it.
    ///
    /// Returns the code and the text before the name, which is the thing to be
    /// translated: "how do you say good morning in french" gives `fr` and
    /// "how do you say good morning".
    static func firstNamed(in text: String) -> (code: String, before: String)? {
        let lowered = text.lowercased()
        for name in namesByLength {
            // Word-boundary sensitive, or "thai" matches inside "thailand".
            guard let range = lowered.range(of: name) else { continue }

            let after = lowered[range.upperBound...].first
            let before = range.lowerBound == lowered.startIndex
                ? nil
                : lowered[lowered.index(before: range.lowerBound)]

            let endsCleanly = after == nil || !(after!.isLetter)
            let startsCleanly = before == nil || !(before!.isLetter)
            guard endsCleanly, startsCleanly else { continue }

            return (byName[name]!, String(text[text.startIndex..<range.lowerBound]))
        }
        return nil
    }

    /// The English name for a code, for FRIDAY to say back.
    static func name(for code: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }
}
