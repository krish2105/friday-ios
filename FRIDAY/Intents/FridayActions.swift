import AppIntents
import Foundation

/// FRIDAY's individual actions, exposed to Shortcuts and Spotlight.
///
/// `AskFridayIntent` already answers anything, but it answers it *as a
/// conversation* — you ask, she speaks. That is the wrong shape for automation:
/// a shortcut wants a **value it can pass to the next step**, and a person
/// typing in Spotlight wants an answer without composing a sentence.
///
/// So each of these returns its result as a `String` value as well as speaking
/// it. "Steps today → if greater than 10,000 → send a message" is a shortcut
/// somebody can actually build, and none of it needs FRIDAY's UI.
///
/// All of them go through `Router` and `Lookup`, so a shortcut and a spoken
/// question take **exactly the same path** and cannot drift apart (D-43). None
/// of them needs an entitlement.
///
/// Reminders, calendar writes and calls are deliberately **absent**. Those stage
/// behind a button press (D-34), and a shortcut running unattended is precisely
/// the situation that rule exists for.

// MARK: - Steps

struct StepsIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Steps"
    static let description = IntentDescription("How many steps you've taken today.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = await MotionTool.answer(aspect: .steps)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

// MARK: - Calendar

struct TodayIntent: AppIntent {
    static let title: LocalizedStringResource = "What's On Today"
    static let description = IntentDescription("Your calendar for today.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = await Lookup.answer(
            for: .calendar(day: "today"),
            reminders: ReminderService(notifier: FridayNotifier()),
            events: EventService(),
            contacts: ContactService()
        )
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

// MARK: - Device

struct DeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Check This Phone"
    static let description = IntentDescription("Battery, storage, signal or temperature.")
    static let openAppWhenRun = false

    @Parameter(title: "What", default: .battery)
    var aspect: DeviceAspect

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = await Lookup.answer(
            for: .device(aspect: aspect.rawValue),
            reminders: ReminderService(notifier: FridayNotifier()),
            events: EventService(),
            contacts: ContactService()
        )
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// A closed set, because Shortcuts needs to offer a menu rather than a free
/// text field the user can get wrong.
enum DeviceAspect: String, AppEnum {
    case battery, storage, network, temperature

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Phone Detail")

    static let caseDisplayRepresentations: [DeviceAspect: DisplayRepresentation] = [
        .battery: "Battery",
        .storage: "Storage",
        .network: "Network",
        .temperature: "Temperature"
    ]
}

// MARK: - Translate

struct TranslateIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate"
    static let description = IntentDescription("Translate a phrase, on device.")
    static let openAppWhenRun = false

    @Parameter(title: "Phrase")
    var phrase: String

    @Parameter(title: "Into", default: "Hindi")
    var language: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let code = Tongues.code(named: language) else {
            let line = "I don't have \(language), boss."
            return .result(value: line, dialog: IntentDialog(stringLiteral: line))
        }

        do {
            let translated = try await Translator().translate(phrase, into: code)
            return .result(value: translated, dialog: IntentDialog(stringLiteral: translated))
        } catch {
            // Each language needs its own downloaded pack, so this is the
            // ordinary case rather than the exception — and the line names which
            // one, because "download it" is useless without that.
            let line = "I'd need \(Tongues.name(for: code)) downloaded first, boss."
            return .result(value: line, dialog: IntentDialog(stringLiteral: line))
        }
    }
}

// MARK: - Reckon

struct ReckonIntent: AppIntent {
    static let title: LocalizedStringResource = "Work It Out"
    static let description = IntentDescription("A sum, a percentage or a unit conversion.")
    static let openAppWhenRun = false

    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Straight through `Router`, so a shortcut and a typed question are the
        // same code rather than two implementations that agree until they don't.
        guard case .reckon(let sum) = Router.intent(for: question) else {
            let line = "I couldn't work that one out, boss."
            return .result(value: line, dialog: IntentDialog(stringLiteral: line))
        }
        let answer = ReckonTool.answer(sum)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}
