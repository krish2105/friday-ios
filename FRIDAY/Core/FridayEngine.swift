import Observation

/// Single source of truth for app state. Views observe it; they never drive
/// speech or model APIs themselves.
@MainActor
@Observable
final class FridayEngine {
    var state: FridayState = .idle {
        didSet {
            guard state != oldValue else { return }
            liveActivity.sync(state: state, snippet: lastReplySnippet)
        }
    }

    /// Grows as partial results arrive while listening; settles to the final
    /// transcript on release.
    private(set) var liveTranscript = ""

    /// The last completed transcript.
    private(set) var lastTranscript = ""

    /// The conversation so far, oldest first.
    private(set) var conversation: [ConversationTurn] = []

    /// Message for the error banner. Set alongside `.error`, cleared when the
    /// user dismisses it or starts another turn.
    private(set) var alert: String?

    let audioSession = AudioSessionManager()
    let speech = SpeechInput()
    let voice = SpeechOutput()
    let reminders: ReminderService
    let language: LanguageEngine
    let liveActivity = LiveActivityController()

    /// Last thing FRIDAY said, for the expanded Dynamic Island.
    private var lastReplySnippet: String {
        conversation.last(where: \.isFriday)?.text ?? ""
    }

    private var partialsTask: Task<Void, Never>?

    init() {
        // The reminder service is shared: the tool stages into it, the UI
        // commits from it. The model can never write on its own.
        let reminders = ReminderService()
        self.reminders = reminders
        self.language = LanguageEngine(reminders: reminders)

        audioSession.onInterruption = { [weak self] interruption in
            guard case .began = interruption else { return }
            // A phone call is not an app error — stop cleanly, keep whatever
            // was transcribed, and wait for a fresh press. Never auto-resume.
            Task { await self?.abortListening() }
        }
    }

    // MARK: - Listening

    func startListening() async {
        // Barge-in: reaching for the button while FRIDAY is talking cuts her
        // off mid-sentence and hands the turn back to you.
        if state == .speaking {
            voice.stop()
            state = .idle
        }

        // Reaching for the button is also a retry. Without this, `.error` is a
        // dead end — CLAUDE.md's machine says any state → error → idle.
        if case .error = state {
            dismissAlert()
        }

        guard state == .idle else { return }

        // Both prompts fire here, on the first press, where the ask makes sense.
        guard await AudioSessionManager.requestMicrophoneAccess() else {
            fail("Microphone access is off. Turn it back on in Settings → FRIDAY → Microphone.")
            return
        }

        guard await SpeechInput.requestRecognitionAccess() else {
            fail("Speech recognition is off. Turn it back on in Settings → FRIDAY → Speech Recognition.")
            return
        }

        do {
            // The session must be active before AVAudioEngine reads its input
            // format, otherwise the format comes back with zero channels.
            try audioSession.activate()

            await speech.prepareAssets()
            guard speech.assetState.isReady else {
                await teardown()
                if case .failed(let reason) = speech.assetState {
                    fail(reason)
                }
                return
            }

            let partials = try await speech.start()
            liveTranscript = ""
            state = .listening
            Haptics.listeningStarted()

            partialsTask = Task { [weak self] in
                for await partial in partials {
                    guard !Task.isCancelled else { return }
                    self?.liveTranscript = partial
                }
            }
        } catch {
            await teardown()
            fail(error.localizedDescription)
        }
    }

    /// Ends the turn, returns the final transcript, and sends it to the model.
    @discardableResult
    func stopListening() async -> String {
        guard state == .listening else { return lastTranscript }

        partialsTask?.cancel()
        partialsTask = nil

        let final = await speech.stop()
        try? audioSession.deactivate()

        lastTranscript = final
        liveTranscript = final
        state = .idle

        await submit(final)
        return final
    }

    // MARK: - Thinking

    /// transcript → .thinking → reply → .idle
    func submit(_ transcript: String) async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state != .thinking else { return }

        alert = nil
        conversation.append(ConversationTurn(speaker: .boss, text: trimmed))
        conversation.append(ConversationTurn(speaker: .friday, text: ""))
        let replyIndex = conversation.count - 1

        state = .thinking

        do {
            // A turn must always end. Nothing in the tool layer has a timeout,
            // so a tool that never returns — a location fix that never
            // arrives, a network path that never reports — wedges the model,
            // which strands the engine in `.thinking`. The talk button only
            // acts when `state == .idle`, so that state is unrecoverable: the
            // app is dead until it is relaunched.
            //
            // Racing the turn against a deadline fixes every cause at once
            // rather than the two that can be named, and losing the race lands
            // in the same in-character failure path as any other error.
            let reply = try await respondWithDeadline(trimmed).get()
            conversation[replyIndex].text = reply.spoken
            conversation[replyIndex].tone = reply.tone
        } catch let failure as LanguageEngineFailure {
            conversation[replyIndex].text = failure.spokenFallback
            conversation[replyIndex].tone = "concerned"
        } catch {
            conversation[replyIndex].text = LanguageEngineFailure
                .other(error.localizedDescription).spokenFallback
            conversation[replyIndex].tone = "concerned"
        }

        Haptics.replyReceived()
        await deliver(conversation[replyIndex].text)
    }

    /// Runs a turn but gives up on it after 20 seconds.
    ///
    /// This deliberately does NOT use a task group. A task group awaits every
    /// child before it returns, so if the model is wedged on a tool that parks
    /// in an unresumed continuation, the group waits for it forever and the
    /// deadline never takes effect. Cancellation does not help either: an
    /// unresumed continuation is not cancellable.
    ///
    /// So the losing side is *abandoned* rather than awaited. A stranded task
    /// is a small leak; a stranded `.thinking` is a dead app, because
    /// `startListening` only acts when `state == .idle`.
    private func respondWithDeadline(_ input: String) async -> Result<FridayReply, Error> {
        /// Guarantees exactly one resume — resuming twice is a crash.
        actor Gate {
            private var taken = false
            func claim() -> Bool {
                guard !taken else { return false }
                taken = true
                return true
            }
        }
        let gate = Gate()

        return await withCheckedContinuation { continuation in
            Task { [language] in
                let outcome: Result<FridayReply, Error>
                do {
                    outcome = .success(try await language.respond(to: input))
                } catch {
                    outcome = .failure(error)
                }
                if await gate.claim() { continuation.resume(returning: outcome) }
            }

            Task { [language] in
                try? await Task.sleep(for: .seconds(20))
                guard await gate.claim() else { return }
                // The abandoned task still holds `isResponding` and still owns
                // the session, so without this the NEXT turn fails too.
                await language.abandonInFlight()
                continuation.resume(returning: .failure(LanguageEngineFailure.timedOut))
            }
        }
    }

    // MARK: - Speaking

    /// .speaking → speak → .idle, unless barge-in took the turn first.
    private func deliver(_ text: String) async {
        guard voice.speakReplies, !text.isEmpty else {
            state = .idle
            return
        }

        state = .speaking

        // One session, activated per phase: echo cancellation stays on and the
        // category never churns mid-conversation. Capture is never running
        // here, so the mic cannot hear FRIDAY's own voice.
        try? audioSession.activate()

        await voice.speak(text)

        // If the user barged in, they now own both the state and the session.
        guard state == .speaking else { return }

        try? audioSession.deactivate()
        state = .idle
    }

    // MARK: - Reminders

    /// User approved the staged reminder. This is the only path that writes.
    func confirmReminder() async {
        let outcome = await reminders.confirm()
        guard !outcome.isEmpty else { return }
        conversation.append(ConversationTurn(speaker: .friday, text: outcome, tone: "calm"))
        await deliver(outcome)
    }

    func cancelReminder() {
        reminders.cancel()
        conversation.append(ConversationTurn(speaker: .friday, text: "Dropped it, boss.", tone: "calm"))
    }

    // MARK: - Failures

    /// Record a failure: banner message plus the `.error` state.
    private func fail(_ message: String) {
        Haptics.failed()
        alert = message
        state = .error(message)
    }

    /// Dismiss the banner and unwind `.error` back to `.idle`.
    func dismissAlert() {
        alert = nil
        if case .error = state { state = .idle }
    }

    // MARK: - Teardown

    private func abortListening() async {
        guard state == .listening else { return }
        partialsTask?.cancel()
        partialsTask = nil
        lastTranscript = await speech.stop()
        try? audioSession.deactivate()
        state = .idle
    }

    private func teardown() async {
        _ = await speech.stop()
        try? audioSession.deactivate()
    }
}
