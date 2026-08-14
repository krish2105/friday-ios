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

    /// Greedy sampling, always.
    ///
    /// The default is random sampling, which on a ~3B model produces exactly
    /// the failure seen on device: "what time is it" answered with "what's for
    /// dinner". It samples a plausible-looking token early and then commits to
    /// it. FRIDAY is a utility assistant, not a creative writer — the same
    /// question should give the same answer, and a wrong-but-fluent reply is
    /// the worst outcome here.
    ///
    /// This also makes the persona and tool-routing rules bind harder, since
    /// the model stops exploring low-probability continuations that ignore
    /// them. `maximumResponseTokens` is a backstop against runaway generation;
    /// it sits well above the ~3-sentence target so it never truncates a real
    /// reply mid-sentence and leaves TTS reading a fragment.
    private static let generation = GenerationOptions(
        sampling: .greedy,
        maximumResponseTokens: 256
    )

    init(reminders: ReminderService) {
        self.reminders = reminders
        session = Self.makeSession(reminders: reminders)
    }

    // MARK: - Session

    // ✅ SEAM RESOLVED (S-4) — verified against the shipping
    // FoundationModels.swiftinterface in the macOS 26 SDK (iOS variant).
    //
    // `LanguageModelSession` ships four initialisers, all with
    // `model:` and `tools:` defaulted:
    //   init(model:tools:instructions: String? = nil)        // @_disfavoredOverload
    //   init(model:tools:@InstructionsBuilder instructions:) // used here
    //   init(model:tools:instructions: Instructions? = nil)
    //   init(model:tools:transcript: Transcript)
    //
    // Correction to D-16's rationale: the `String?` overload accepts a String
    // *constant* perfectly well, so `instructions: FridayPersona.instructions`
    // would also have compiled. The builder form is kept because it is the
    // non-disfavoured overload and reads better — not because it was required.
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
            // Streaming yields `ResponseStream<FridayReply>.Snapshot`, NOT the
            // partial directly. `snapshot.content` is the
            // `FridayReply.PartiallyGenerated`, where every property is
            // optional until the model has filled it in.
            let stream = session.streamResponse(
                to: prompt(for: input),
                generating: FridayReply.self,
                options: Self.generation
            )

            var spoken: String?
            var tone: String?

            for try await snapshot in stream {
                if let text = snapshot.content.spoken {
                    spoken = text
                    partialSpoken = text
                }
                if let mood = snapshot.content.tone {
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

    // ✅ SEAM RESOLVED (S-5) — verified against the shipping
    // FoundationModels.swiftinterface. `GenerationError` has exactly nine
    // cases, every one carrying a `Context`:
    //   exceededContextWindowSize, assetsUnavailable, guardrailViolation,
    //   unsupportedGuide, unsupportedLanguageOrLocale, decodingFailure,
    //   rateLimited, concurrentRequests, refusal(Refusal, Context)
    //
    // Per D-17 only the three needing distinct handling are matched by name.
    // The names used below are confirmed correct. `default:` covers the other
    // six and also absorbs any case Apple adds, with no @unknown warning.
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
