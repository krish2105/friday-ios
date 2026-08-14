import AVFoundation
import Foundation
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

    /// The language the current turn is in. Carried on the engine rather than
    /// passed around because the reminder buttons answer outside `submit`, and
    /// conversing in Hindi and then being told "Added it, boss" in English is
    /// the kind of seam that makes an assistant feel assembled from parts.
    private(set) var tongue: Tongue = .english

    /// Whether the streaming reply is worth showing.
    ///
    /// False for a Hindi turn: the model produces English, and watching English
    /// stream past before it is replaced wholesale by the Hindi reply is worse
    /// than watching the thinking indicator.
    var streamsVisibly: Bool { tongue == .english }

    /// Raised when a turn asks FRIDAY to read something. `ContentView` binds the
    /// picker and the scanner to these, which is why they are not
    /// `private(set)` — dismissing either has to be able to lower its own flag.
    var showPhotoPicker = false
    var showCamera = false

    let audioSession = AudioSessionManager()
    let speech = SpeechInput()
    let voice = SpeechOutput()
    let reminders: ReminderService
    let events = EventService()
    let contacts = ContactService()
    let notifier = FridayNotifier()
    let language: LanguageEngine
    let translator = Translator()
    let liveActivity = LiveActivityController()

    /// Last thing FRIDAY said, for the expanded Dynamic Island.
    private var lastReplySnippet: String {
        conversation.last(where: \.isFriday)?.text ?? ""
    }

    private var partialsTask: Task<Void, Never>?

    init() {
        // The reminder service is shared: the tool stages into it, the UI
        // commits from it. The model can never write on its own.
        //
        // It holds the notifier because who nudges — FRIDAY or Apple Reminders
        // — is decided at the moment the reminder is written, not before.
        let reminders = ReminderService(notifier: notifier)
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

        // Hindi is handled on either side of the model, never by it — the model
        // does not support Hindi and the transcriber cannot even hear it. See
        // `Translator`. Everything downstream of this line is English, so
        // `Router`, `Lookup` and the persona are all untouched by bilingual
        // support.
        tongue = Bilingual.tongue(of: trimmed)
        let asked: String
        if tongue == .hindi {
            do {
                asked = try await translator.english(from: trimmed)
            } catch {
                // `english(from:)` uses typed throws, so this is already a
                // `TranslatorFailure` and carries its own spoken line. The
                // commonest one by far is the pack simply not being downloaded,
                // which is a Settings trip, not a fault.
                conversation[replyIndex].text = error.spokenFallback
                conversation[replyIndex].tone = "concerned"
                Haptics.failed()
                await deliver(error.spokenFallback)
                return
            }
        } else {
            asked = trimmed
        }

        // Swift routes; the model only speaks. See `Intent` for why.
        let intent = Router.intent(for: asked)

        // Reading is the one route that needs something from the user before it
        // can answer, so it cannot go through `Lookup` like the others.
        // `raiseScanner` puts the camera or the picker up *before* the reply is
        // spoken — `deliver` waits on the whole utterance, and it should already
        // be sliding into view while she says this.
        if case .scan(let source) = intent {
            let answer = await voiced(await raiseScanner(source), factual: false)
            conversation[replyIndex].text = answer
            conversation[replyIndex].tone = "calm"
            await deliver(answer)
            return
        }

        if case .chat = intent {} else {
            // `factual: true` — these carry the numbers D-44 exists to protect.
            let answer = await voiced(await lookup(intent), factual: true)
            conversation[replyIndex].text = answer
            conversation[replyIndex].tone = "calm"
            Haptics.replyReceived()
            await deliver(answer)
            return
        }

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
            // `asked`, not `trimmed` — the model only ever sees English.
            let reply = try await respondWithDeadline(asked).get()
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

        // Once, after the catches, so a failure line comes back in his language
        // too. `factual: false` — a conversational reply has no number D-44
        // protects, and dropping to English mid-conversation reads worse than a
        // loosely translated sentence.
        conversation[replyIndex].text = await voiced(conversation[replyIndex].text, factual: false)

        Haptics.replyReceived()
        await deliver(conversation[replyIndex].text)
    }

    /// Puts a finished English sentence into the language the turn was asked in.
    ///
    /// Everything upstream composes in English — `Lookup`, the persona, the
    /// failure fallbacks — so this is the single place a reply changes language,
    /// and English turns pass through it untouched.
    private func voiced(_ english: String, factual: Bool) async -> String {
        guard tongue == .hindi, !english.isEmpty else { return english }
        return factual
            ? await translator.hindiPreservingNumbers(from: english)
            : (try? await translator.hindi(from: english)) ?? english
    }

    /// Runs the tool a routed turn asked for and writes the sentence here.
    ///
    /// The model never sees these. It echoed `TimeTool`'s string word for word
    /// on device, and a 3B model paraphrasing a number can quietly change it —
    /// the worst failure an assistant has. Composing in Swift means the value
    /// is always right and "boss" is always present.
    private func lookup(_ intent: Intent) async -> String {
        await Lookup.answer(for: intent, reminders: reminders, events: events, contacts: contacts)
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
                language.abandonInFlight()
                continuation.resume(returning: .failure(LanguageEngineFailure.timedOut))
            }
        }
    }

    // MARK: - Reading

    /// Longer than this and the text gets summarised instead of read out. A
    /// sign, a label or a line off a receipt is quicker to just hear; a page is
    /// not, and this is spoken aloud.
    private static let readAloudLimit = 240

    /// How much of a long document goes to the model. It shares a ~4,096 token
    /// context with the persona and the conversation, and D-18's overflow path
    /// can only reset the session — it cannot make the text fit.
    private static let promptLimit = 4_000

    /// Puts the right way of getting a picture on screen, and returns the line
    /// FRIDAY says while it arrives.
    ///
    /// The camera falls back to the photo library rather than failing when the
    /// scanner is unsupported — the Simulator, mostly, where a black screen and
    /// no explanation would be the worst of both.
    private func raiseScanner(_ source: ScanSource) async -> String {
        guard source == .camera, DocumentCamera.isAvailable else {
            showPhotoPicker = true
            return "Show me, boss."
        }

        // Asked here, on the turn that needs it, exactly as the microphone is in
        // `startListening`. The refusal is spoken rather than banner-ed because
        // a turn is already in flight and it names the way back itself.
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            return "Camera access is off, boss. Turn it back on in Settings → FRIDAY → Camera."
        }

        showCamera = true
        return "Hold it steady, boss."
    }

    /// Text recognised from a picked image, answered like any other turn.
    ///
    /// The recognised text always goes on screen **verbatim, composed here in
    /// Swift**. The model may summarise it aloud but can never replace what is
    /// shown — same reasoning as D-44, where a quietly paraphrased number is the
    /// worst failure an assistant has. A summary you can check against the text
    /// beside it is a different thing from a summary you have to take on trust.
    ///
    /// `Data` rather than `CGImage` on purpose — see `TextScanner.text(in:)`.
    /// An array because the document camera returns a page at a time; the photo
    /// picker passes exactly one, and an empty array is a picture that would not
    /// load, which earns the same in-character line as one that will not read.
    func scan(_ pages: [Data]) async {
        // Picking is quick enough to land while she is still saying "show me",
        // and `.speaking` would otherwise fail the guard below and drop the
        // scan silently. Same barge-in as reaching for the talk button.
        if state == .speaking {
            voice.stop()
            state = .idle
        }
        guard state == .idle else { return }

        showPhotoPicker = false
        showCamera = false
        alert = nil
        state = .thinking

        let text: String
        do {
            text = try await TextScanner.text(in: pages)
        } catch {
            // Only `ScanError` has a line FRIDAY can say. A raw Vision error
            // must never reach him — CLAUDE.md's persona contract holds on the
            // failure paths too, not just the happy one.
            let line = (error as? TextScanner.ScanError)?.errorDescription
                ?? "That one wouldn't read, boss."
            conversation.append(ConversationTurn(speaker: .friday,
                                                 text: await voiced(Lookup.addressed(line),
                                                                    factual: false),
                                                 tone: "concerned"))
            Haptics.failed()
            await deliver(conversation[conversation.count - 1].text)
            return
        }

        // A receipt is worth more than a summary of a receipt, so it gets first
        // refusal. Three gates, and any of them declining costs nothing but the
        // ordinary summary below: Swift decides it looks like a receipt at all,
        // the model picks the fields out, and Swift then refuses any field it
        // cannot find in the page. See `ReceiptReader`.
        if ReceiptReader.looksLikeReceipt(text),
           let extracted = await language.receipt(in: text),
           let receipt = ReceiptReader.verified(extracted, against: text) {
            let line = await voiced(ReceiptReader.sentence(for: receipt), factual: true)
            conversation.append(ConversationTurn(speaker: .friday, text: text, tone: "calm"))
            conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
            Haptics.replyReceived()
            await deliver(line)
            return
        }

        // Short enough to hear: one turn, spoken exactly as it is shown. The
        // recognised text is carried through whole and unedited — the wrapper
        // only puts "boss" in front of it, because the persona contract holds on
        // this path as much as any other.
        guard text.count > Self.readAloudLimit else {
            // Only the wrapper changes language. The recognised text is what the
            // page says and is quoted, not spoken by FRIDAY — translating it
            // would be inventing a document that does not exist.
            let line = await voiced("Here's what it says, boss.", factual: false) + " " + text
            conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
            Haptics.replyReceived()
            await deliver(line)
            return
        }

        // Too long to hear: the text goes up on its own, unspoken, and the model
        // gets a turn to say what it amounts to.
        conversation.append(ConversationTurn(speaker: .friday, text: text, tone: "calm"))
        conversation.append(ConversationTurn(speaker: .friday, text: "", tone: "calm"))
        let replyIndex = conversation.count - 1

        let ask = """
        This is text I just read off a picture for the boss. Tell him what it \
        says, in under three sentences.

        \(text.prefix(Self.promptLimit))
        """

        switch await respondWithDeadline(ask) {
        case .success(let reply):
            conversation[replyIndex].text = reply.spoken
            conversation[replyIndex].tone = reply.tone
        case .failure(let error):
            let failure = error as? LanguageEngineFailure
                ?? .other(error.localizedDescription)
            conversation[replyIndex].text = failure.spokenFallback
            conversation[replyIndex].tone = "concerned"
        }

        conversation[replyIndex].text = await voiced(conversation[replyIndex].text, factual: false)

        Haptics.replyReceived()
        await deliver(conversation[replyIndex].text)
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
        let outcome = await voiced(await reminders.confirm(), factual: true)
        guard !outcome.isEmpty else { return }
        conversation.append(ConversationTurn(speaker: .friday, text: outcome, tone: "calm"))
        await deliver(outcome)
    }

    func cancelReminder() async {
        reminders.cancel()
        let line = await voiced("Dropped it, boss.", factual: false)
        conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
    }

    // MARK: - Calendar events
    //
    // Same shape as reminders, deliberately. The model stages; a real press
    // writes (D-34).

    func confirmEvent() async {
        let outcome = await voiced(await events.confirm(), factual: true)
        guard !outcome.isEmpty else { return }
        conversation.append(ConversationTurn(speaker: .friday, text: outcome, tone: "calm"))
        await deliver(outcome)
    }

    func cancelEvent() async {
        events.cancel()
        let line = await voiced("Left it off, boss.", factual: false)
        conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
    }

    // MARK: - Calling
    //
    // The only path that dials. `Router` has known phrasing gaps and a false
    // positive here rings a real person, so the press is the safety.

    func cancelCall() async {
        contacts.cancelCall()
        let line = await voiced("Left it, boss.", factual: false)
        conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
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
