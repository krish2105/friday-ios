import AppIntents
import Foundation
import SwiftUI

/// Answers a question with no speech, no audio session and no UI.
///
/// Deliberately separate from `FridayEngine`. The engine owns `AVAudioEngine`
/// and the audio session, and an App Intent answering Siri must never touch
/// either — Siri already owns the microphone and the speaker at that moment.
/// Routing and lookups are shared through `Router` and `Lookup`, so a spoken
/// answer and a typed one come from exactly the same code.
@MainActor
enum FridayAnswer {
    static func text(for question: String) async -> String {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return "Didn't catch that, boss." }

        var intent = Router.intent(for: asked)

        // Reminders stay UI-gated even here (D-34). A 3B model must never be
        // able to write to real Reminders, and Siri has no Add it button to
        // press — so this stages nothing and sends him to the app.
        if case .reminder = intent {
            return "Reminders need a tap to confirm, boss. Open FRIDAY and I'll set it up."
        }

        // Calendar writes are the same shape and the same rule.
        if case .event = intent {
            return "Calendar entries need a tap to confirm, boss. Open FRIDAY and I'll set it up."
        }

        // A lookup is fine here; *offering to dial* is not, because there is no
        // button to press. The number is read out instead, which is the useful
        // half and none of the risk.
        if case .contact(let name, let aspect, true) = intent {
            intent = .contact(name: name, aspect: aspect, callable: false)
        }

        if case .chat = intent {
            let language = LanguageEngine(reminders: ReminderService(notifier: FridayNotifier()))
            do {
                return try await language.respond(to: asked).spoken
            } catch let failure as LanguageEngineFailure {
                return failure.spokenFallback
            } catch {
                return LanguageEngineFailure.other("").spokenFallback
            }
        }

        return await Lookup.answer(
            for: intent,
            reminders: ReminderService(notifier: FridayNotifier()),
            events: EventService(),
            contacts: ContactService()
        )
    }
}

/// "Hey Siri, ask FRIDAY what time it is."
struct AskFridayIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask FRIDAY"
    static let description = IntentDescription(
        "Ask FRIDAY a question and get the answer spoken back."
    )

    /// Answered in place. Opening the app would defeat the point — the whole
    /// value here is getting an answer without leaving what you were doing.
    static let openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What do you need, boss?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        let answer = await FridayAnswer.text(for: question)
        // Spoken *and* shown. The dialog is what Siri says; the snippet is what
        // Siri and Spotlight draw, and without it the answer is a grey bubble
        // indistinguishable from any other app's.
        return .result(
            dialog: IntentDialog(stringLiteral: answer),
            snippetIntent: FridayAnswerSnippet(answer: answer)
        )
    }
}

/// Makes the intent discoverable without the user building a shortcut by hand.
///
/// Every phrase must contain `\(.applicationName)` — App Intents rejects any
/// that does not.
///
/// **The question cannot be part of the phrase.** Interpolating `\(\.$question)`
/// fails to build:
///
///     error: Invalid parameter type. AppEntity and AppEnum are the only
///     allowed types for question
///
/// Only `AppEntity` and `AppEnum` parameters may appear in a spoken phrase, and
/// the whole point here is an *open* question, which is neither. So Master
/// Build §13's "Hey Siri, ask FRIDAY what time it is" cannot work as one
/// utterance. Saying "Hey Siri, ask FRIDAY" makes Siri ask "What do you need,
/// boss?" and the answer comes back spoken — two turns instead of one.
///
/// A fixed `AppEnum` of canned questions would buy the one-shot phrasing at the
/// cost of only ever answering a hardcoded list, which is a worse assistant.
/// This is a platform limit, documented rather than worked around — the same
/// call the README makes about always-on wake words.
struct FridayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskFridayIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Brief me, \(.applicationName)",
                "\(.applicationName) status"
            ],
            shortTitle: "Ask FRIDAY",
            systemImageName: "waveform.circle"
        )
    }
}
