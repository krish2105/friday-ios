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
    var showFilePicker = false
    var showLiveScanner = false

    /// A link found in a code, waiting on a press.
    ///
    /// Staged rather than opened. A QR code is untrusted input from the physical
    /// world — anyone can print a sticker and put it on a parking meter — so the
    /// full address goes on a card to be read before anything happens. D-34's
    /// rule against an unattended write, applied to an unattended *navigation*.
    private(set) var pendingLink: URL?

    /// A screenshot was just taken. Offered, never acted on — reading someone's
    /// screen unasked is not a feature.
    private(set) var offeringScreenshot = false

    /// A business card read off a page, waiting on a press before it is written
    /// to the address book (D-34).
    private(set) var pendingCard: BusinessCard?

    /// When set, every turn is translated into this language instead of routed.
    /// Nil is the normal state.
    ///
    /// Not `private(set)`: the mode needs a way out that is a **button**, not a
    /// phrase. A mode whose only exit is speaking the right words is one you can
    /// be stuck in — and while translating, the wrong words get translated
    /// rather than understood.
    var translatingInto: String?

    /// The last thing read, for a turn that says "add *that*".
    ///
    /// Session-scoped and never written to disk — it is part of a conversation,
    /// and conversations here are ephemeral by decision.
    private(set) var lastScan: ScanFollowUp.Scanned?

    /// What the picture now being chosen is *for*.
    ///
    /// Reset to `.read` after every scan rather than left set. A purpose that
    /// outlived its turn would make the next plain "read this" silently
    /// translate, and a mode nobody asked to be in is the failure this app has
    /// already fixed once, in the live-translation stage.
    private var pendingScanPurpose: ScanPurpose = .read

    /// Which photos the picker offers. Screenshots only when the offer raised
    /// it, so he is not hunting through a year of pictures for the one he took
    /// four seconds ago.
    private(set) var wantsScreenshotsOnly = false

    func cancelLink() {
        pendingLink = nil
    }

    /// The one thing awaiting a press, if anything is.
    ///
    /// Four services can each have something staged, and modelling them as four
    /// sibling cards let two be on screen at once, squeezing the conversation
    /// between them. Precedence is **fixed and deliberate** rather than
    /// most-recent-wins: two staged actions at once is rare, and a rule you can
    /// read beats a timestamp you cannot.
    ///
    /// An error comes first because it is the only one that is *blocking* rather
    /// than offered — everything else can wait behind a failure that needs
    /// dismissing.
    var pendingAction: PendingAction? {
        if let alert { return .error(alert) }
        if let call = contacts.pendingCall {
            return .call(name: call.name, number: call.number)
        }
        if let pendingLink { return .link(pendingLink) }
        if let card = pendingCard {
            return .saveContact(name: card.name, detail: CardReader.detail(for: card))
        }
        if offeringScreenshot { return .readScreenshot }
        if let reminder = reminders.pending {
            return .reminder(
                title: reminder.title,
                detail: reminder.spokenWhen.prefix(1).uppercased() + reminder.spokenWhen.dropFirst()
            )
        }
        if let event = events.pending {
            return .event(
                title: event.title,
                detail: event.spokenWhen.prefix(1).uppercased() + event.spokenWhen.dropFirst()
            )
        }
        return nil
    }

    /// Dismisses whatever is pending, whichever it is.
    func cancelPending() async {
        switch pendingAction {
        case .error: dismissAlert()
        case .call: await cancelCall()
        case .link: cancelLink()
        case .reminder: await cancelReminder()
        case .event: await cancelEvent()
        case .saveContact: pendingCard = nil
        case .readScreenshot: offeringScreenshot = false
        case .none: break
        }
    }

    /// Commits whatever is pending. The link case is the view's, because opening
    /// a URL belongs to the environment rather than the engine.
    func confirmPending() async {
        switch pendingAction {
        case .reminder: await confirmReminder()
        case .event: await confirmEvent()
        case .error: dismissAlert()
        case .saveContact: await saveCard()
        case .readScreenshot: readScreenshot()
        case .call, .link, .none: break
        }
    }

    /// The screenshot offer, raised by `ContentView` when iOS says one was taken.
    ///
    /// Offered rather than acted on, and the picker is the mechanism on purpose:
    /// `PhotosPicker` runs **out of process**, so FRIDAY never gains photo
    /// library access and only ever receives the one image he chose. Reaching
    /// into PhotoKit for "the most recent screenshot" would need a permission,
    /// and would be reading his screen without being asked to.
    func offerScreenshot() {
        guard state == .idle, !offeringScreenshot else { return }
        offeringScreenshot = true
    }

    private func readScreenshot() {
        offeringScreenshot = false
        wantsScreenshotsOnly = true
        showPhotoPicker = true
    }

    func clearPhotoFilter() {
        wantsScreenshotsOnly = false
    }

    private func saveCard() async {
        guard let card = pendingCard else { return }
        pendingCard = nil
        let outcome = await voiced(await CardReader.save(card), factual: true)
        conversation.append(ConversationTurn(speaker: .friday, text: outcome, tone: "calm"))
        await deliver(outcome)
    }

    let audioSession = AudioSessionManager()
    let speech = SpeechInput()
    let voice = SpeechOutput()
    let reminders: ReminderService
    let events = EventService()
    let contacts = ContactService()
    let notifier = FridayNotifier()
    let language: LanguageEngine
    let translator = Translator()

    /// The other ear — sounds rather than speech. Never runs at the same time as
    /// `speech`: both want the input node, and `state == .idle` is what keeps
    /// them apart.
    let ears = SoundListener()
    let liveActivity = LiveActivityController()
    let timerActivity = TimerActivityController()

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

        // Auto-stop (D-09). The detector ends the turn when he stops talking;
        // releasing the button still ends it too, and `stopListening` guards on
        // `.listening` so whichever is second does nothing.
        speech.onSilence = { [weak self] in
            Task { await self?.stopListening() }
        }

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

        // Acting on the last scan, before routing. "Add that to my calendar"
        // has no subject of its own — it borrows one from what was just read —
        // so `Router` would see a calendar write with the word "that" as its
        // title. The back-reference has to be resolved before routing, not by it.
        if let scan = lastScan, ScanFollowUp.isFollowUp(trimmed) {
            await act(on: scan, wantsReminder: ScanFollowUp.wantsReminder(trimmed), at: replyIndex)
            return
        }

        // Swift routes; the model only speaks. See `Intent` for why.
        let intent = Router.intent(for: asked)

        // While translating, everything **except leaving the mode** is a phrase
        // to translate rather than a question to answer. Checked here, after
        // routing, so the one intent that can end the mode still gets through —
        // a mode you cannot leave by speaking is a trap.
        if let target = translatingInto, !isLeaving(intent) {
            await translate(trimmed, into: target, at: replyIndex, twoWay: true)
            return
        }

        if case .startTranslating(let code) = intent {
            translatingInto = code
            let line = "Translating into \(Tongues.name(for: code)) now, boss. Say stop when you're done."
            conversation[replyIndex].text = await voiced(line, factual: false)
            conversation[replyIndex].tone = "calm"
            Haptics.replyReceived()
            await deliver(conversation[replyIndex].text)
            return
        }

        if case .stopTranslating = intent {
            let was = translatingInto.map(Tongues.name(for:))
            translatingInto = nil
            let line = was.map { "Done with the \($0), boss." } ?? "I wasn't translating, boss."
            conversation[replyIndex].text = line
            conversation[replyIndex].tone = "calm"
            Haptics.replyReceived()
            await deliver(line)
            return
        }

        // Reading is the one route that needs something from the user before it
        // can answer, so it cannot go through `Lookup` like the others.
        // `raiseScanner` puts the camera or the picker up *before* the reply is
        // spoken — `deliver` waits on the whole utterance, and it should already
        // be sliding into view while she says this.
        // Like `.scan`, this cannot go through `Lookup`: it needs the translator
        // the engine owns, and it is the one reply spoken in a voice that is not
        // FRIDAY's own.
        if case .translate(let phrase, let code) = intent {
            await translate(phrase, into: code, at: replyIndex)
            return
        }

        // A timer is a local notification rather than a countdown the app has to
        // stay alive to run — the only design that survives being backgrounded,
        // which is where a phone spends most of its life. It reuses the notifier
        // reminders already have.
        if case .timer(let seconds) = intent {
            let due = Date().addingTimeInterval(TimeInterval(seconds))
            let spoken = TimerTool.spoken(seconds)
            let set = await notifier.nudge("your \(spoken) timer is up", at: due)

            // The Island shows it running; the notification is what actually
            // fires. Deliberately independent — a Live Activity can be disabled
            // system-wide, and a timer that only existed there would silently
            // never go off.
            if set { timerActivity.start(label: spoken, deadline: due) }

            let line = set
                ? "Timer set for \(spoken), boss."
                : "I need notifications switched on to time that, boss. They're in Settings, under FRIDAY."
            conversation[replyIndex].text = await voiced(line, factual: true)
            conversation[replyIndex].tone = set ? "calm" : "concerned"
            Haptics.replyReceived()
            await deliver(conversation[replyIndex].text)
            return
        }

        if case .listen = intent {
            await listenForSound(at: replyIndex)
            return
        }

        if case .scan(let source, let purpose) = intent {
            // Set before the picker goes up, because by the time a photo comes
            // back the sentence that asked for it is long gone — the picker
            // hands back `[Data]` and nothing else. This is the whole reason the
            // purpose rides on the intent rather than being re-derived later.
            pendingScanPurpose = purpose
            let answer = await voiced(await raiseScanner(source, purpose: purpose), factual: false)
            conversation[replyIndex].text = answer
            conversation[replyIndex].tone = "calm"
            await deliver(answer)
            return
        }

        if case .chat = intent {} else {
            // Bounded, like every other long path — and this one was the
            // exception. A tool has no timeout of its own: `CMPedometer`,
            // `EKEventStore` and `CNContactStore` all sit behind callbacks that
            // are *not obliged to fire*, and the first motion query raises a
            // permission prompt whose handler may never arrive. An unresumed
            // continuation is not cancellable, so the turn strands in
            // `.thinking` and the talk button's `state == .idle` guard makes the
            // app unusable until it is relaunched (HANDOVER §7).
            //
            // Twelve seconds: a lookup that takes longer has failed, whatever it
            // says it is doing.
            let looked = await withDeadline(seconds: 12) { [weak self] in
                await self?.lookup(intent)
            }

            // `factual: true` — these carry the numbers D-44 exists to protect.
            let answer = await voiced(
                looked ?? "That one's not answering, boss. Give it another go.",
                factual: true
            )
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

    // MARK: - Translating a phrase

    /// "How do you say ‹phrase› in ‹language›" — answered in that language, and
    /// spoken in a voice that can pronounce it.
    ///
    /// The reply is the translation and **nothing else**: no "boss", no English
    /// frame. Hearing it said properly is the entire value of the question, and
    /// an English voice wrapping a French phrase mangles the one part that
    /// matters. The persona contract is not broken so much as inapplicable —
    /// this is a quotation, the same as the recognised text of a scanned page,
    /// which also carries no form of address.
    /// Whether an intent is the one that ends translation mode.
    ///
    /// Only `.stopTranslating` gets out. Everything else — including asking the
    /// time — is a phrase to translate while the mode is on, because that is
    /// what the mode *is*. A mode that silently answers some turns and
    /// translates others would be unpredictable in the worst way: you would not
    /// know which you were getting until it happened.
    private func isLeaving(_ intent: Intent) -> Bool {
        if case .stopTranslating = intent { return true }
        return false
    }

    /// Turns a phrase into the other language and speaks it there.
    ///
    /// `twoWay` is what makes the mode usable in an actual conversation rather
    /// than a one-sided broadcast. With it on, the **direction is chosen from
    /// the script of what was typed**: Devanagari goes back to English, anything
    /// else goes to the target. So in Hindi mode, you type English and they read
    /// Hindi, they type Hindi and you read English — one mode, both directions,
    /// no switch to remember.
    ///
    /// It only works where the two languages use different scripts, which is
    /// exactly why it is not attempted for French or Spanish: those share the
    /// Latin alphabet with English, and D-56 measured that
    /// `NLLanguageRecognizer` cannot be trusted to tell them apart in short
    /// phrases. For those the mode is one-way, which is honest and still useful.
    private func translate(
        _ phrase: String,
        into code: String,
        at replyIndex: Int,
        twoWay: Bool = false
    ) async {
        var code = code

        if twoWay, code == "hi", Bilingual.tongue(of: phrase) == .hindi {
            code = "en"
        }

        await performTranslation(phrase, into: code, at: replyIndex)
    }

    private func performTranslation(_ phrase: String, into code: String, at replyIndex: Int) async {
        do {
            let translated = try await translator.translate(phrase, into: code)
            conversation[replyIndex].text = translated
            conversation[replyIndex].tone = "calm"
            Haptics.replyReceived()
            await deliver(translated, in: code)
        } catch {
            // Every language has its own pack, so "not downloaded" is the
            // ordinary case here rather than the exception — and the line names
            // which language, because "download it" is useless without that.
            let language = Tongues.name(for: code)
            let line = switch error {
            case .notDownloaded:
                "I'd need \(language) downloaded first, boss. It's in Settings, Apps, Translate, Downloaded Languages."
            case .failed:
                "That one didn't translate, boss. Try me again?"
            }
            conversation[replyIndex].text = await voiced(line, factual: false)
            conversation[replyIndex].tone = "concerned"
            Haptics.failed()
            await deliver(conversation[replyIndex].text)
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

    /// How much recognised text goes **on screen**.
    ///
    /// This limit exists because its absence hung the app. A photographed page
    /// is a page; a PDF's text layer is not, and an eight-page document can be
    /// tens of thousands of characters — all of which landed in a single `Text`
    /// carrying `.fixedSize(horizontal: false, vertical: true)`, which by
    /// definition cannot truncate and must measure the whole thing.
    ///
    /// On device, reading a two-page CV stalled the main thread past the
    /// ten-second scene-update watchdog and iOS killed the app:
    /// `WatchdogEvent: scene-update`, main thread inside
    /// `TransitionHelper.update()`, and **no PDFKit, Vision or model work in any
    /// thread of the report**. The parse was fine. The view was the fault.
    private static let displayLimit = 1_200

    /// The recognised text, bounded, and honest about what it left out.
    ///
    /// D-44's guarantee is that a summary can be *checked* against its source,
    /// not that every character is rendered. An excerpt that states how much
    /// more there is keeps that guarantee; a view that hangs the app keeps
    /// nothing at all. Verification and the model prompt both still run against
    /// the **full** text — only the display is bounded.
    private static func excerpt(of text: String) -> String {
        guard text.count > displayLimit else { return text }
        return text.prefix(displayLimit)
            + "…\n\n[\(text.count - displayLimit) more characters not shown]"
    }

    /// Puts the right way of getting a picture on screen, and returns the line
    /// FRIDAY says while it arrives.
    ///
    /// The camera falls back to the photo library rather than failing when the
    /// scanner is unsupported — the Simulator, mostly, where a black screen and
    /// no explanation would be the worst of both.
    private func raiseScanner(_ source: ScanSource, purpose: ScanPurpose = .read) async -> String {
        // Naming the language up front is not decoration: it is the only chance
        // he gets to notice FRIDAY heard the wrong one *before* spending a
        // camera, an OCR pass and a translation on it.
        let holdSteady: String
        if case .translate(let code) = purpose {
            holdSteady = "Hold it steady, boss — I'll put it into \(Tongues.name(for: code))."
        } else {
            holdSteady = "Hold it steady, boss."
        }

        if source == .files {
            showFilePicker = true
            return "Point me at it, boss."
        }

        // The one place this app changes behaviour rather than answering a
        // question. Holding a phone up to read a menu while driving is the
        // single worst thing anything here could invite, and a viewfinder is an
        // invitation. The library and Files are left alone — those need no
        // camera and no aiming.
        //
        // Fail-safe by construction: `isDriving` is bounded at two seconds and
        // answers false on any delay, refusal or unavailability, so the camera
        // behaves exactly as it did before for everyone else.
        if source == .camera || source == .live, await ActivityTool.isDriving() {
            return "You're driving, boss. I'll read it when you've stopped."
        }

        // Live and document capture both need the camera, and both fall back to
        // the photo library rather than presenting a black rectangle.
        if source == .live, LiveScanner.isAvailable {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                return "Camera access is off, boss. Turn it back on in Settings → FRIDAY → Camera."
            }
            showLiveScanner = true
            return "Point it at the code, boss."
        }

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
        return holdSteady
    }

    /// A code's contents, said out loud and — if it is a link — staged.
    private func report(code payload: String) async {
        let classified = BarcodeReader.classify(payload)
        if case .link(let url) = classified { pendingLink = url }

        let line = await voiced(BarcodeReader.sentence(for: classified), factual: true)
        conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
        Haptics.replyReceived()
        await deliver(line)
    }

    /// Something tapped in the live viewfinder — a code, or a line of text.
    func liveRecognised(_ payload: String, isCode: Bool) async {
        showLiveScanner = false

        if state == .speaking {
            voice.stop()
            state = .idle
        }
        guard state == .idle else { return }
        state = .thinking

        if isCode {
            await report(code: payload)
            return
        }

        // Plain text off a sign. Short by nature, so it is read straight back
        // rather than summarised — the whole point was to know what it said.
        let line = await voiced("It says: \(payload)", factual: true)
        conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
        Haptics.replyReceived()
        await deliver(line)
    }

    /// A PDF chosen from Files.
    func readFile(_ url: URL) async {
        if state == .speaking {
            voice.stop()
            state = .idle
        }
        guard state == .idle else { return }

        showFilePicker = false
        alert = nil
        state = .thinking

        // Bounded like every other long operation. A scanned PDF is up to eight
        // pages of OCR, and this was the one path added without a deadline while
        // all its siblings had one — which would strand `.thinking` and leave a
        // dead app (HANDOVER §7).
        let outcome: Result<String, Error>? = await withDeadline(seconds: 45) {
            do { return .success(try await PDFReader.text(in: url)) }
            catch { return .failure(error) }
        }

        switch outcome {
        case .success(let text):
            await present(scanned: text)

        case .failure(let error):
            let line = (error as? PDFReader.PDFError)?.errorDescription
                ?? (error as? TextScanner.ScanError)?.errorDescription
                ?? "That file wouldn't read, boss."
            await say(Lookup.addressed(line))

        case .none:
            await say("That file's taking too long, boss. Try a shorter one?")
        }
    }

    /// One in-character failure line: shown, spoken, and back to idle.
    private func say(_ line: String) async {
        let spoken = await voiced(line, factual: false)
        conversation.append(ConversationTurn(speaker: .friday, text: spoken, tone: "concerned"))
        Haptics.failed()
        await deliver(spoken)
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

        // A code found in a still beats reading the page it is printed on. The
        // code *is* the content — a parcel label's whole point is the tracking
        // number, not the courier's address in six-point type.
        if let payload = await BarcodeReader.codes(in: pages).first {
            await report(code: payload)
            return
        }

        // Asked outright to say what's in it — no OCR attempted at all, because
        // "what am I looking at" is not a request to read anything.
        if case .describe = pendingScanPurpose {
            pendingScanPurpose = .read
            await describe(pages)
            return
        }

        let text: String
        do {
            text = try await TextScanner.text(in: pages)
        } catch {
            // A picture with no words in it is not a failure, and answering it
            // as one was the old behaviour: "There's no text in that one" is
            // what a scanner says, not what an assistant says. Photograph a dog
            // and being told the dog contains no text is a small insult. So an
            // empty read becomes a description instead.
            if let scanError = error as? TextScanner.ScanError, case .empty = scanError {
                pendingScanPurpose = .read
                await describe(pages)
                return
            }

            // Anything else genuinely is a failure. Only `ScanError` has a line
            // FRIDAY can say — a raw Vision error must never reach him, because
            // CLAUDE.md's persona contract holds on the failure paths too.
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

        await present(scanned: text)
    }

    /// Says what's in a picture that has no words in it.
    ///
    /// Composed in Swift from the classifier's labels (D-44). These are labels
    /// with confidences, not a description, and handing them to a 3B model to
    /// make prose from is exactly how "dog 0.44" becomes a confident story about
    /// somebody's garden.
    private func describe(_ pages: [Data]) async {
        guard let first = pages.first else {
            await say("Nothing came through, boss. Try that again?")
            return
        }

        let outcome = await withDeadline(seconds: 15) {
            await SceneReader.read(first)
        }

        guard let outcome else {
            await say("I couldn't make that one out, boss.")
            return
        }

        let line = await voiced(SceneReader.sentence(for: outcome.labels,
                                                     smudged: outcome.smudged),
                                factual: true)
        conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
        Haptics.replyReceived()
        await deliver(line)
    }

    /// Listens to the room for a few seconds and names what it heard.
    ///
    /// The reply arrives in two parts on purpose. FRIDAY says she is listening
    /// *before* the window opens, because twelve seconds of a silent screen is
    /// indistinguishable from a hang — and this app has shipped one of those
    /// already (HANDOVER §7). The line is replaced in place when she is done.
    ///
    /// Composed in Swift, never by the model (D-44). What was heard is a
    /// measurement with a confidence attached, and a 3B model handed
    /// "dog_bark 0.41" would happily upgrade it to a certainty.
    private func listenForSound(at replyIndex: Int) async {
        // The talk button and this share one microphone, so the listen cannot
        // start while she is still speaking her own line into it.
        voice.stop()

        conversation[replyIndex].text = await voiced("Listening, boss — give me a few seconds.",
                                                     factual: false)
        conversation[replyIndex].tone = "calm"

        // Bounded past its own window, like every long path here. The listener
        // stops itself after `SoundListener.window`; this is the backstop for a
        // microphone that never yields a buffer at all, which would otherwise
        // strand `.thinking` and leave a dead app.
        let heard: [SoundListener.Heard] = await withDeadline(
            seconds: SoundListener.window + 8
        ) { [weak self] () async -> [SoundListener.Heard]? in
            guard let self else { return nil }
            return await self.ears.listen()
        } ?? []

        let line = Self.sentence(forHeard: heard)
        conversation[replyIndex].text = await voiced(line, factual: true)
        conversation[replyIndex].tone = heard.isEmpty ? "concerned" : "calm"
        Haptics.replyReceived()
        await deliver(conversation[replyIndex].text)
    }

    /// What she says about what she heard.
    ///
    /// A second guess is offered only when it is genuinely close to the first —
    /// within three quarters of its confidence. Listing every candidate would
    /// turn a confident answer into a hedge, and hedging on all three is how an
    /// assistant stops being worth asking.
    static func sentence(forHeard heard: [SoundListener.Heard]) -> String {
        guard let best = heard.first else {
            return "Nothing I can put a name to, boss. Too quiet, or nothing I know."
        }

        let confident = best.confidence >= 0.6
        let opening = confident ? "That's" : "Sounds like"

        guard let second = heard.dropFirst().first,
              second.confidence >= best.confidence * 0.75
        else {
            return "\(opening) \(best.spoken), boss."
        }

        return "\(opening) \(best.spoken), boss — could be \(second.spoken)."
    }

    /// A page read in one language and shown in another.
    ///
    /// **The translation goes on screen verbatim and is composed in Swift**, the
    /// same rule the ordinary scan path follows: the model never sees this text
    /// and cannot paraphrase it. That matters more here than anywhere else in the
    /// app — the entire premise is that he *cannot read the original*, so there
    /// is nothing to check a wrong answer against. A summary you can't verify is
    /// the one kind of answer this project refuses to give.
    ///
    /// Both are kept on screen, original above translation. A menu you can point
    /// at is worth more than a translation you can only read out.
    private func present(translating text: String, into target: String) async {
        switch SightTranslator.reading(of: text, into: target) {
        case .translatable(let source, let destination):
            let trimmed = SightTranslator.capped(text)
            let wasCapped = trimmed.count < text.count

            // Bounded like every other long path. A page of translation is a
            // sequence of model calls inside the framework, and this was the one
            // new path that could strand `.thinking` (HANDOVER §7).
            let translated: String? = await withDeadline(seconds: 30) { [weak self] in
                guard let self else { return nil }
                return try? await self.translator.translate(trimmed, from: source, into: destination)
            }

            guard let translated else {
                // A missing pack is by far the likeliest cause, and it is fixable
                // — so the line says which language and where, rather than
                // "something went wrong".
                await say("I'd need \(Tongues.name(for: source)) downloaded first, boss. "
                          + "Settings, Apps, Translate, Downloaded Languages.")
                return
            }

            let line = await voiced(
                SightTranslator.sentence(for: .translatable(from: source, to: destination),
                                         wasCapped: wasCapped),
                factual: true
            )
            conversation.append(ConversationTurn(speaker: .friday,
                                                 text: Self.excerpt(of: translated),
                                                 tone: "calm",
                                                 kind: .quoted))
            conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
            Haptics.replyReceived()

            // Spoken in the language it was translated *into*, not FRIDAY's.
            // Reading Hindi text aloud in an English voice is noise, and the
            // synthesiser has `Lekha` for exactly this.
            await deliver(line)
            await voice.speak(Self.excerpt(of: translated), in: destination)

        case let other:
            // Already in that language, unsupported, or unreadable — each names
            // itself. The text still goes up, because he asked to see it.
            conversation.append(ConversationTurn(speaker: .friday,
                                                 text: Self.excerpt(of: text),
                                                 tone: "calm",
                                                 kind: .quoted))
            await say(SightTranslator.sentence(for: other))
        }
    }

    /// Stages a calendar entry or a reminder from what was just read.
    ///
    /// Staged, never written — D-34 holds here exactly as it does for a spoken
    /// request, and arguably harder: the subject came off a photograph, so the
    /// chance of it being wrong is higher, not lower.
    private func act(on scan: ScanFollowUp.Scanned, wantsReminder: Bool, at replyIndex: Int) async {
        let line: String

        if wantsReminder {
            reminders.stage(title: scan.title, when: scan.text)
            line = reminders.pending.map {
                "That's \($0.title), \($0.spokenWhen), boss. Say the word and I'll add it."
            } ?? "I couldn't work out when, boss."
        } else if scan.date != nil, events.stage(title: scan.title, when: scan.text),
                  let pending = events.pending {
            line = "That's \(pending.title), \(pending.spokenWhen), boss. Say the word and I'll add it."
        } else {
            // No date on the page. Asking is the honest answer — the alternative
            // is inventing a time for something read off a poster.
            line = "I couldn't find a date on that one, boss. When should I put it down for?"
        }

        conversation[replyIndex].text = await voiced(line, factual: true)
        conversation[replyIndex].tone = "calm"
        Haptics.replyReceived()
        await deliver(conversation[replyIndex].text)
    }

    /// What to do with recognised text, whatever produced it.
    ///
    /// Extracted so a **PDF is answered exactly as a photograph is** — receipt
    /// extraction, boarding pass, read-aloud or summary. A file having arrived
    /// through Files rather than a camera changes nothing about what should
    /// happen to the words in it, and duplicating this would have let the two
    /// paths drift apart.
    private func present(scanned text: String) async {
        // Remembered so the next turn can say "add that to my calendar".
        lastScan = ScanFollowUp.scanned(text)

        // Taken and cleared in one move. Every path below returns, so a purpose
        // left set here would leak into the next scan.
        let purpose = pendingScanPurpose
        pendingScanPurpose = .read

        if case .translate(let target) = purpose {
            await present(translating: text, into: target)
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
            conversation.append(ConversationTurn(speaker: .friday, text: Self.excerpt(of: text), tone: "calm", kind: .quoted))
            conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
            Haptics.replyReceived()
            await deliver(line)
            return
        }

        // A boarding pass, same three gates as a receipt and the same fallback
        // if any of them declines. Checked first because a pass often carries a
        // fare total too, and the flight is the more useful answer.
        if BoardingPassReader.looksLikeBoardingPass(text),
           let extracted = await language.boardingPass(in: text),
           let pass = BoardingPassReader.verified(extracted, against: text) {
            let line = await voiced(BoardingPassReader.sentence(for: pass), factual: true)
            conversation.append(ConversationTurn(speaker: .friday, text: Self.excerpt(of: text), tone: "calm", kind: .quoted))
            conversation.append(ConversationTurn(speaker: .friday, text: line, tone: "calm"))
            Haptics.replyReceived()
            await deliver(line)
            return
        }

        // A business card. Same three gates, and the strictest verification of
        // the three document types — these fields are about to be written into
        // the address book rather than read aloud and forgotten.
        if CardReader.looksLikeCard(text),
           let extracted = await language.businessCard(in: text),
           let card = CardReader.verified(extracted, against: text) {
            pendingCard = card
            let line = await voiced(CardReader.sentence(for: card), factual: true)
            conversation.append(ConversationTurn(speaker: .friday, text: Self.excerpt(of: text),
                                                 tone: "calm", kind: .quoted))
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
        conversation.append(ConversationTurn(speaker: .friday, text: Self.excerpt(of: text), tone: "calm", kind: .quoted))
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
    private func deliver(_ text: String, in language: String? = nil) async {
        guard voice.speakReplies, !text.isEmpty else {
            state = .idle
            return
        }

        state = .speaking

        // One session, activated per phase: echo cancellation stays on and the
        // category never churns mid-conversation. Capture is never running
        // here, so the mic cannot hear FRIDAY's own voice.
        try? audioSession.activate()

        await voice.speak(text, in: language)

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
