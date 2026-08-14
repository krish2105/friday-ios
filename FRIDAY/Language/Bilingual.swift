import Foundation

/// Which language a turn is in. FRIDAY answers in the language she was asked in.
enum Tongue: Equatable, Sendable {
    case english
    case hindi
}

/// The two pieces of bilingual logic that are pure text, kept out of
/// `Translator` so they can be tested without a language pack installed.
enum Bilingual {

    // MARK: - Which language

    /// Devanagari (U+0900–U+097F) means Hindi; anything else is treated as
    /// English.
    ///
    /// Script rather than `NLLanguageRecognizer` on purpose. Detection here has
    /// to be *certain*, because getting it wrong sends a perfectly good English
    /// turn through two translation hops and back. Script is deterministic and
    /// free; a statistical recogniser on a three-word utterance is neither.
    ///
    /// **The known limit:** romanised Hindi — "kya haal hai" — reads as English
    /// and goes straight to the model, which will make a poor job of it. That is
    /// the same failure a Router phrasing gap has, and the same fix: it falls
    /// through to the path that at least tries, rather than to a wrong one. A
    /// recogniser would not reliably catch it either.
    static func tongue(of text: String) -> Tongue {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
            ? .hindi
            : .english
    }

    // MARK: - Numbers must survive

    /// True when every number in `source` still appears in `translated`.
    ///
    /// This is D-44 applied to a translator instead of a language model. The
    /// factual answers are composed in Swift precisely so a number can never be
    /// paraphrased into a different number, and machine-translating that
    /// sentence hands the number to a model again. So the invariant is checked
    /// in code rather than trusted: if a digit went missing, the caller keeps
    /// the English sentence, which is right but in the wrong language — a far
    /// better failure than a fluent Hindi sentence quoting the wrong time.
    ///
    /// Devanagari digits are folded to ASCII first. A translator rendering 87 as
    /// ८७ has preserved the number perfectly well, and failing that case would
    /// make the whole feature look broken.
    static func preservesNumbers(from source: String, in translated: String) -> Bool {
        let found = numbers(in: translated)
        return numbers(in: source).allSatisfy(found.contains)
    }

    /// Runs of digits, with Devanagari digits folded to ASCII.
    private static func numbers(in text: String) -> Set<String> {
        var numbers: Set<String> = []
        var current = ""

        for scalar in text.unicodeScalars {
            if let digit = asciiDigit(scalar) {
                current.append(digit)
            } else if !current.isEmpty {
                numbers.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { numbers.insert(current) }
        return numbers
    }

    /// `0`–`9` as themselves, `०`–`९` (U+0966–U+096F) folded onto them.
    private static func asciiDigit(_ scalar: Unicode.Scalar) -> Character? {
        switch scalar.value {
        case 0x30...0x39: Character(scalar)
        case 0x0966...0x096F: Character(UnicodeScalar(scalar.value - 0x0966 + 0x30)!)
        default: nil
        }
    }
}
