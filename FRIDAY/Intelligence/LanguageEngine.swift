import FoundationModels
import Observation

/// Failures the user might actually hit, each with a line FRIDAY can say.
///
/// Raw framework errors never reach the user or the model's context.
enum LanguageEngineFailure: Error, Equatable, Sendable {
    case guardrail
    case contextOverflow
    case modelUnavailable
    case other(String)

    /// What FRIDAY says when this happens. Always in character.
    var spokenFallback: String {
        switch self {
        case .guardrail:
            "I'd rather not take that one, boss."
        case .contextOverflow:
            "Losing the thread a bit, boss. Starting fresh."
        case .modelUnavailable:
            "I'm not all here right now, boss — Apple Intelligence isn't available."
        case .other:
            "Something went sideways, boss. Say the word and I'll try again."
        }
    }
}

/// Wraps `LanguageModelSession` and the FRIDAY persona.
@MainActor
@Observable
final class LanguageEngine {
    /// The reply as it streams in. Bound to the in-flight bubble so words
    /// appear as the model produces them.
    private(set) var partialSpoken = ""
    private(set) var isResponding = false

    private var session: LanguageModelSession
    private let model = SystemLanguageModel.default

    /// The last completed exchange, carried across a context-overflow reset so
    /// FRIDAY doesn't lose the thread mid-topic.
    private var lastExchange: (boss: String, friday: String)?
    private var pendingCarryOver: String?

    private let reminders: ReminderService

    init(reminders: ReminderService) {
        self.reminders = reminders
        session = Self.makeSession(reminders: reminders)
    }

    // MARK: - Session

    // ⚠️ API SEAM — the only place a session is constructed.
    //
    // The initialiser is `@InstructionsBuilder instructions: () throws -> Instructions`,
    // so the persona is passed as a trailing closure. The commonly-shown
    // `LanguageModelSession(instructions: "…")` form works for a string
    // *literal*, but `FridayPersona.instructions` is a `String` constant, which
    // is why the builder form is used here.
    private static func makeSession(reminders: ReminderService) -> LanguageModelSession {
        LanguageModelSession(
            tools: [
                TimeTool(),
                DeviceTool(),
                WeatherTool(),
                CalendarTool(),
                ReminderTool(service: reminders)
            ]
        ) {
            FridayPersona.instructions
        }
    }

    /// Fresh session with the persona intact. History is dropped; the last
    /// exchange is re-seeded into the next prompt.
    private func resetPreservingPersona() {
        session = Self.makeSession(reminders: reminders)
        if let last = lastExchange {
            pendingCarryOver = """
            For context, boss said earlier: "\(last.boss)" and you replied: \
            "\(last.friday)".
            """
        }
    }

    // MARK: - Responding

    /// Send a transcript and get a FRIDAY-voiced reply.
    ///
    /// Throws `LanguageEngineFailure`, which always carries a spoken fallback.
    func respond(to input: String) async throws -> FridayReply {
        try await respond(to: input, allowingReset: true)
    }

    private func respond(to input: String, allowingReset: Bool) async throws -> FridayReply {
        guard case .available = model.availability else {
            throw LanguageEngineFailure.modelUnavailable
        }
        guard !isResponding else {
            throw LanguageEngineFailure.other("Already responding")
        }

        isResponding = true
        partialSpoken = ""
        defer { isResponding = false }

        do {
            // Streaming yields `FridayReply.PartiallyGenerated`, where every
            // property is optional until the model has filled it in.
            let stream = session.streamResponse(
                to: prompt(for: input),
                generating: FridayReply.self
            )

            var spoken: String?
            var tone: String?

            for try await partial in stream {
                if let text = partial.spoken {
                    spoken = text
                    partialSpoken = text
                }
                if let mood = partial.tone {
                    tone = mood
                }
            }

            guard let spoken else {
                throw LanguageEngineFailure.other("Empty reply")
            }

            let reply = FridayReply(spoken: spoken, tone: tone ?? "calm")
            lastExchange = (boss: input, friday: spoken)
            return reply

        } catch let error as LanguageModelSession.GenerationError {
            let failure = Self.classify(error)

            // Overflow is recoverable exactly once: reset, then retry the same
            // input on the fresh session so the turn isn't lost.
            if failure == .contextOverflow, allowingReset {
                resetPreservingPersona()
                isResponding = false
                return try await respond(to: input, allowingReset: false)
            }
            throw failure

        } catch let failure as LanguageEngineFailure {
            throw failure
        } catch {
            throw LanguageEngineFailure.other(error.localizedDescription)
        }
    }

    // MARK: - Error mapping

    // ⚠️ API SEAM — `GenerationError` has nine cases in iOS 26. Only the three
    // that need distinct handling are matched by name; the rest fall through.
    private static func classify(_ error: LanguageModelSession.GenerationError) -> LanguageEngineFailure {
        switch error {
        case .exceededContextWindowSize:
            .contextOverflow
        case .guardrailViolation:
            .guardrail
        case .assetsUnavailable:
            .modelUnavailable
        default:
            .other(error.localizedDescription)
        }
    }

    // MARK: - Prompt

    private func prompt(for input: String) -> String {
        guard let carryOver = pendingCarryOver else { return input }
        pendingCarryOver = nil
        return carryOver + "\n\n" + input
    }
}
