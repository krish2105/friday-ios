import Foundation
import Observation
import Translation

/// Hindi in, Hindi out, entirely on device.
///
/// FRIDAY cannot think in Hindi and cannot hear it. Measured against the
/// shipping frameworks on 2026-08-15 rather than assumed:
///
/// | Layer | Hindi |
/// |---|---|
/// | `SpeechTranscriber.supportedLocales` | **no** — 30 locales, none Hindi |
/// | `SystemLanguageModel.supportedLanguages` | **no** — 23 languages, `supportsLocale(hi_IN)` is false |
/// | `LanguageAvailability.supportedLanguages` | **yes** — 38 languages including `hi-Deva-IN`, both directions |
/// | `AVSpeechSynthesisVoice` | **yes** — `Lekha`, `hi-IN` |
///
/// So the model stays English and this sits on either side of it: Hindi in
/// becomes English for `Router` and the model, and the reply becomes Hindi
/// again on the way out. `Router` and all 34 of its truth-table cases are
/// untouched, because they never see anything but English.
///
/// **Voice input in Hindi is not possible at all** — the transcriber has no
/// Hindi locale, not a poor one. Typed Hindi, or spoken English. That is a
/// platform limit in the same class as the wake word: documented, not worked
/// around.
@MainActor
@Observable
final class Translator {

    /// Why a Hindi turn could not be handled, each with a line FRIDAY can say.
    enum TranslatorFailure: Error, Equatable {
        /// The pack exists but has not been downloaded.
        case notDownloaded
        case failed

        var spokenFallback: String {
            switch self {
            case .notDownloaded:
                "I can't read Hindi yet, boss. Download it in Settings, Apps, Translate, "
                    + "Downloaded Languages, and I'll pick it up from there."
            case .failed:
                "I lost that one in translation, boss. Say it again?"
            }
        }
    }

    private static let hindi = Locale.Language(identifier: "hi")
    private static let english = Locale.Language(identifier: "en")

    /// Whether the Hindi pack is downloaded. `nil` until first asked.
    ///
    /// Surfaced so `SettingsView` can tell him where to get it, which is the
    /// same treatment the Premium voices get — there is no API to offer the
    /// download in-app, so pointing at Settings is genuinely the best available.
    private(set) var isDownloaded: Bool?

    // MARK: - Availability

    /// Checks the pack, caching the answer.
    ///
    /// `TranslationSession(installedSource:)` is the direct initialiser added in
    /// iOS 26, so this needs no SwiftUI attachment and the engine can own it —
    /// unlike the photo picker. The catch, verified on the SDK: a session built
    /// that way reports `canRequestDownloads == false` and throws
    /// `TranslationError.notInstalled`, so it cannot fetch the pack itself. That
    /// is why this reports rather than downloads.
    @discardableResult
    func refreshAvailability() async -> Bool {
        let status = await LanguageAvailability().status(from: Self.hindi, to: Self.english)
        let ready = status == .installed
        isDownloaded = ready
        return ready
    }

    // MARK: - Translating

    /// Hindi → English, for `Router` and the model.
    func english(from hindi: String) async throws(TranslatorFailure) -> String {
        try await translate(hindi, from: Self.hindi, to: Self.english)
    }

    /// English → anything the framework supports, for "how do you say ‹x› in ‹y›".
    ///
    /// Each target needs **its own** downloaded pack, exactly as Hindi does —
    /// having Hindi installed does nothing for French. So `.notDownloaded` is
    /// the ordinary case here rather than the exception, and the caller names
    /// the language in the line it says back.
    func translate(_ english: String, into code: String) async throws(TranslatorFailure) -> String {
        try await translate(
            english,
            from: Self.english,
            to: Locale.Language(identifier: code)
        )
    }


    /// English → Hindi, for what FRIDAY says back.
    func hindi(from english: String) async throws(TranslatorFailure) -> String {
        try await translate(english, from: Self.english, to: Self.hindi)
    }

    /// A session is built per call and never stored, which is the point.
    ///
    /// Holding one and reusing it does not compile under strict concurrency:
    /// `TranslationSession` is not `Sendable`, so handing a stored one to an
    /// `async` method is *"sending `self.session` risks causing data races"*.
    /// The compiler is right rather than pedantic — a turn can suspend inside
    /// `translate`, and the next turn would reach the same session while the
    /// first is still inside it.
    ///
    /// A local the compiler can prove is uniquely owned has no such problem, and
    /// removes the hazard instead of silencing it. `@preconcurrency import`
    /// would have demoted this to a warning, which is worse twice over: the race
    /// stays, and the zero-warning build stops meaning anything. The cost is
    /// building a session per translation, which is noise beside a turn that
    /// already takes seconds.
    private func translate(
        _ text: String,
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws(TranslatorFailure) -> String {
        // Hindi is the conversational path — asked on most turns, so its answer
        // is cached. Any other language is asked about fresh: it comes up
        // rarely, and each language has a pack of its own, so having Hindi
        // installed says nothing about French.
        if source.languageCode?.identifier == "hi" || target.languageCode?.identifier == "hi" {
            // Written out rather than `isDownloaded ?? (await …)`: `??` takes an
            // autoclosure, and an autoclosure cannot be async.
            var ready = isDownloaded
            if ready == nil { ready = await refreshAvailability() }
            guard ready == true else { throw .notDownloaded }
        } else {
            guard await LanguageAvailability().status(from: source, to: target) == .installed else {
                throw .notDownloaded
            }
        }

        do {
            let session = TranslationSession(installedSource: source, target: target)
            return try await session.translate(text).targetText
        } catch {
            // Re-check the pack next time, in case it was removed underneath us.
            isDownloaded = nil
            throw .failed
        }
    }

    // MARK: - Guarded translation

    /// Translates a **factual** sentence to Hindi, or returns the English if a
    /// number did not survive.
    ///
    /// D-44 says factual answers are composed in Swift so a number can never be
    /// paraphrased into a different number. Handing that sentence to a
    /// translator hands the number back to a model, so the invariant is checked
    /// rather than trusted — see `Bilingual.preservesNumbers`. Chat turns do not
    /// go through here: there is no number in them that D-44 protects, and
    /// falling back to English on a conversational reply would be a worse
    /// outcome than a loosely translated one.
    func hindiPreservingNumbers(from english: String) async -> String {
        guard let translated = try? await hindi(from: english) else { return english }
        return Bilingual.preservesNumbers(from: english, in: translated) ? translated : english
    }
}
