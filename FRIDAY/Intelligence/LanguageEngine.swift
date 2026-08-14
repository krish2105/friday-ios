import FoundationModels
import Observation

/// Failures the user might actually hit, each with a line FRIDAY can say.
///
/// Raw framework errors never reach the user or the model's context.
enum LanguageEngineFailure: Error, Equatable, Sendable {
    case guardrail
    case contextOverflow
    case modelUnavailable
    /// The turn never came back. A tool with no timeout can wedge the model
    /// indefinitely, and a wedged turn leaves the engine in `.thinking`, where
    /// the talk button's `state == .idle` guard makes the app unusable until
    /// it is relaunched. This is the backstop for that.
    case timedOut
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
        case .timedOut:
            "That one's taking too long, boss. Give it another go."
        case .other:
            "Something went sideways, boss. Say the word and I'll try again."
        }
    }
}

/// Guarantees exactly one resume of a continuation — resuming twice is a crash.
///
/// At file scope because a type cannot be nested inside a generic function.
private actor ResumeGate {
    private var taken = false

    func claim() -> Bool {
        defer { taken = true }
        return !taken
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

    /// Seeded top-3 sampling. This replaces `.greedy`, and the reason is a
    /// device failure, not a preference.
    ///
    /// D-45 chose `.greedy` because unseeded random sampling answered "what
    /// time is it" with "what's for dinner" — it samples a plausible-looking
    /// token early and commits to it. FRIDAY is a utility assistant, not a
    /// creative writer, so the same question should give the same answer.
    ///
    /// Both halves of that reasoning have since stopped holding:
    ///
    /// - **The failure it prevented is now structurally impossible.** Since the
    ///   routing rewrite (D-43), "what time is it" is answered in Swift and
    ///   never reaches the model at all. Only conversational turns get here.
    /// - **Greedy is what caused the loop.** Argmax at every step is
    ///   deterministic, so once the model enters a repetition cycle it re-picks
    ///   the same tokens forever. Observed on device on 2026-08-15: "what
    ///   languages do you know" produced the same run of language names over
    ///   and over until the 20s deadline killed it, at which point FRIDAY said
    ///   "That one's taking too long, boss" about a turn that was working
    ///   exactly as instructed.
    ///
    /// `seed:` is what makes this a fix rather than a trade. Reproducibility
    /// was D-45's actual requirement, and a pinned seed delivers it — the same
    /// prompt gives the same reply — while `top: 3` keeps the model near the
    /// argmax it would have taken anyway. Cycles still break, because within a
    /// single generation the RNG state has advanced by the time the repeated
    /// context comes round again, so the second visit does not draw the same
    /// token as the first.
    ///
    /// Still no `maximumResponseTokens`, and D-45 is right about why: guided
    /// generation has to emit a COMPLETE structured value, so a cap landing
    /// mid-structure leaves `spoken` nil and the turn dies as "Empty reply".
    /// `trimmedAtRepetition` bounds the output instead, in Swift, where a
    /// partial answer can be kept rather than thrown away.
    private static let generation = GenerationOptions(sampling: .random(top: 3, seed: 1))

    init(reminders: ReminderService) {
        self.reminders = reminders
        session = Self.makeSession()
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
    /// Whether `WeatherTool` is worth registering.
    ///
    /// `false` because WeatherKit needs a paid developer account (D-32) and the
    /// owner is on a free one, so every `currentWeather` call is guaranteed to
    /// fail — after spending a location fix first. Registering a tool that
    /// cannot succeed is pure cost: it takes schema tokens from the ~4,096
    /// budget it shares with the persona and the conversation (D-36), and on
    /// device the model routed "what can you do" to it and wedged the turn.
    ///
    /// This does not reverse D-32, it follows it. `WeatherTool` is untouched;
    /// flip this the day the account is upgraded and the capability is enabled.
    private static let weatherIsUsable = false

    /// No tools. This session only ever handles conversational turns.
    ///
    /// `Router` decides in Swift whether a turn needs a lookup and runs the
    /// tool itself, so anything reaching the model needs nothing looked up.
    /// Registering tools here would only let the model fire one on a chat turn
    /// — which is exactly what it did, answering "what can you do" with the
    /// battery level.
    ///
    /// It also hands the persona and the conversation the entire ~4,096 token
    /// budget that four tool schemas used to share (D-36), so context overflow
    /// arrives much later.
    ///
    /// `WeatherTool`, `TimeTool`, `DeviceTool`, `CalendarTool` and
    /// `ReminderTool` all still conform to `Tool` and are unchanged, so
    /// re-registering them is a one-line change if the model ever gets good
    /// enough to route for itself.
    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession {
            FridayPersona.instructions
        }
    }

    /// Let go of a turn the engine gave up waiting for.
    ///
    /// When `FridayEngine`'s deadline abandons a turn, the stranded task still
    /// holds `isResponding` and still owns the session. Without this, the very
    /// next turn fails its `!isResponding` guard, or the framework reports
    /// concurrent requests — either way the user gets "Something went sideways,
    /// boss" on a turn that would have been fine. The session is rebuilt
    /// because whatever the abandoned request left in it cannot be trusted.
    func abandonInFlight() {
        guard isResponding else { return }
        isResponding = false
        partialSpoken = ""
        resetPreservingPersona()
    }

    /// Fresh session with the persona intact. History is dropped; the last
    /// exchange is re-seeded into the next prompt.
    private func resetPreservingPersona() {
        session = Self.makeSession()
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

                    // Stop the moment it starts going round in circles.
                    //
                    // Nothing downstream can do this. The model is producing
                    // tokens happily, so `FridayEngine`'s 20s deadline sees a
                    // perfectly healthy turn and kills it on the clock instead
                    // of on the fault; and there is deliberately no token cap
                    // (see `generation`) to run out. The bound has to be here,
                    // where the text can be salvaged rather than discarded.
                    if let salvaged = Self.trimmedAtRepetition(text) {
                        spoken = salvaged
                        partialSpoken = salvaged
                        break
                    }
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

    // MARK: - Receipts

    /// Pulls the fields off a receipt, on a session of its own.
    ///
    /// Separate from the conversational session on purpose. That one carries the
    /// persona and the whole exchange, and pouring a page of recognised text
    /// into it would spend the ~4,096 token budget D-36 protects on a one-shot
    /// job that has nothing to do with the conversation — and leave the page
    /// sitting in the transcript afterwards, steering every later reply.
    ///
    /// Seeded top-3 rather than greedy, same as D-53. Copying is exactly the
    /// task argmax is best at, but a `String` field in guided generation is
    /// unbounded and greedy is what loops; and the answer is verified against
    /// the page regardless, so a worse pick is caught rather than believed.
    ///
    /// `nil` on anything going wrong. There is nothing to say about a failed
    /// extraction that the ordinary summary does not say better.
    func receipt(in text: String) async -> Receipt? {
        guard case .available = model.availability else { return nil }

        return await bounded(seconds: 20) {
            let session = LanguageModelSession {
                """
                You read receipts. Copy each field exactly as it is printed. \
                Never calculate a total, never reformat a date, never guess at \
                a name. If a field is not printed, return an empty string.
                """
            }
            return try? await session.respond(
                to: text,
                generating: Receipt.self,
                options: Self.generation
            ).content
        }
    }

    /// Races `work` against a deadline, abandoning the loser.
    ///
    /// A wedged extraction would strand `FridayEngine` in `.thinking`, which
    /// HANDOVER §7 calls a dead app — the talk button only acts on `.idle`.
    ///
    /// Deliberately its own copy of the race rather than a generalisation of
    /// `FridayEngine.respondWithDeadline`. That one is hard-won, subtle and
    /// verified on device, and a one-shot extraction is not worth reopening it.
    private func bounded<T: Sendable>(
        seconds: Int,
        _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        let gate = ResumeGate()

        return await withCheckedContinuation { continuation in
            Task {
                let value = await work()
                if await gate.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if await gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: - Repetition

    /// Sixty characters is the window. Natural language does not repeat sixty
    /// characters exactly by accident; a decoder stuck in a cycle repeats them
    /// forever. Below three windows there isn't enough text to tell the two
    /// apart, so short replies are never inspected.
    private static let loopWindow = 60

    /// The reply cut at the point it began repeating itself, or `nil` if it
    /// never did.
    ///
    /// Everything before the first repeat is the part the model actually meant.
    /// For the question that exposed this — "what languages do you know" — that
    /// prefix is a perfectly good list of languages, so the turn is salvaged
    /// instead of failed. Reporting a fault to the boss for an answer that was
    /// sitting right there would be the worse outcome.
    private static func trimmedAtRepetition(_ text: String) -> String? {
        guard text.count >= loopWindow * 3 else { return nil }

        let tail = text.suffix(loopWindow)
        let head = text.dropLast(loopWindow)
        guard let repeated = head.firstRange(of: tail) else { return nil }

        let kept = text[text.startIndex..<repeated.lowerBound]

        // Cut back to the last clause boundary so it can't end mid-word. Without
        // this the reply is spoken aloud with a severed final word.
        guard let boundary = kept.lastIndex(where: { ",;:".contains($0) }) else {
            return String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(kept[..<boundary]) + "."
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
