import AVFoundation
import Observation
import Speech

/// State of the on-device language assets transcription needs.
///
/// CLAUDE.md's trap table calls this out: if the assets aren't downloaded, the
/// first transcription fails silently. It has to be visible in the UI.
enum SpeechAssetState: Equatable, Sendable {
    case unknown
    /// Downloading. Fraction is `nil` when the system reports no progress.
    case preparing(Double?)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

enum SpeechInputError: LocalizedError {
    case notPrepared
    case inputUnavailable
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            "Speech assets aren't ready yet."
        case .inputUnavailable:
            "The microphone input is unavailable."
        case .converterUnavailable:
            "Couldn't match the microphone format to the speech model."
        }
    }
}

/// On-device speech-to-text via the iOS 26 Speech framework.
///
/// Owns the whole capture path — `AVAudioEngine`, the format conversion, the
/// analyser and the input level — because two taps on the same input node
/// conflict, so there can only be one audio owner.
///
/// `SpeechDetector` is now present, and D-09 is closed. It was kept out because
/// it did not conform to `SpeechModule` — an Apple bug with a stated expiry —
/// and the shipping iOS 26 SDK declares `final public class SpeechDetector :
/// Speech.SpeechModule`, verified against the real `iPhoneOS26.5.sdk` rather
/// than the Mac Catalyst interface the first check used. Krishna chose to adopt
/// it on 2026-08-15.
///
/// **It is behind `autoStop`, and "off" is a true revert rather than a variant.**
/// With the toggle off the analyser is built with `[transcriber]` exactly as it
/// was before, so the escape hatch restores byte-for-byte the path that Sessions
/// 2–7 verified. This is the most crash-prone file in the project — both runtime
/// traps came from here — and a new module in the capture graph deserves a way
/// back that is not "hope the new code is correct".
@MainActor
@Observable
final class SpeechInput {
    private(set) var assetState: SpeechAssetState = .unknown

    /// 0…1 input level, mapped from dBFS with a −50 dB floor.
    private(set) var level: Float = 0

    /// Whether FRIDAY stops listening when he stops talking.
    var autoStop: Bool {
        didSet { UserDefaults.standard.set(autoStop, forKey: "friday.autoStop") }
    }

    /// Called on the main actor when speech has stopped for `silenceWindow`.
    ///
    /// Release-to-send still works and still wins — `stopListening` guards on
    /// `state == .listening`, so whichever arrives second is a no-op. A detector
    /// that never fires therefore degrades to exactly the old behaviour.
    var onSilence: (() -> Void)?

    /// How long a silence must last before the turn is treated as over.
    ///
    /// 1.5s rather than something snappier because it has to survive a pause for
    /// breath mid-sentence. Cutting a man off while he is still thinking is a
    /// worse failure than waiting half a second too long.
    private static let silenceWindow: Duration = .milliseconds(1500)

    private let audioEngine = AVAudioEngine()

    /// Rebuilt per turn alongside the transcriber — assumed single-use for the
    /// same reason, since nothing says otherwise and reusing the transcriber
    /// trapped inside the framework.
    private var detector: SpeechDetector?
    private var detectorTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var lastSpeechAt: ContinuousClock.Instant?

    init() {
        autoStop = UserDefaults.standard.object(forKey: "friday.autoStop") as? Bool ?? true
    }

    /// Resolved once by `prepareAssets()` and reused. The *locale* is what is
    /// durable here — the transcriber built from it is not (see `start()`).
    private var locale: Locale?

    /// Rebuilt every turn. Never reuse one across turns.
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Never>?
    private var isCapturing = false

    // MARK: - Permission

    /// Speech recognition permission.
    ///
    /// `SpeechAnalyzer` needs this in addition to microphone access, even
    /// though transcription is entirely on-device. `SFSpeechRecognizer` is used
    /// here *only* to request authorisation — transcription itself is pure
    /// iOS 26 `SpeechAnalyzer`, with no legacy fallback.
    ///
    /// `nonisolated` is REQUIRED, and its absence was a hard crash on device.
    ///
    /// This type is `@MainActor`, so without it this static func is
    /// MainActor-isolated and the `requestAuthorization` completion handler
    /// below inherits that isolation. TCC invokes that handler on its own
    /// background XPC queue, Swift 6's runtime checks the executor, finds a
    /// mismatch and traps:
    ///
    ///     _dispatch_assert_queue_fail
    ///     _swift_task_checkIsolatedSwift
    ///     closure #1 in closure #1 in static SpeechInput.requestRecognitionAccess()
    ///     TCC __TCCAccessRequest_block_invoke_8
    ///
    /// The compiler cannot catch this: isolation inheritance through a
    /// non-Sendable closure parameter is legal at compile time and only fails
    /// at runtime, so it survived a zero-warning strict-concurrency build.
    ///
    /// Nothing here touches main-actor state — it calls a class method and
    /// resumes a continuation, both safe from any thread — so dropping the
    /// isolation is correct rather than a workaround.
    ///
    /// Compare `SynthesisObserver` and `LocationFix`: both put their callbacks
    /// in a separate non-isolated NSObject, which is why neither has this bug.
    nonisolated static func requestRecognitionAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Assets

    /// Resolve a locale and make sure its model is installed. Safe to call
    /// repeatedly; it no-ops once ready.
    ///
    /// ✅ VERIFIED on device by temporarily forcing this branch: the red banner
    /// appears, the engine returns to `.idle` rather than hanging in
    /// `.listening`, the text field keeps working, and pressing the orb again
    /// re-runs rather than dying — both of D-29's recovery routes.
    ///
    /// It cannot be reached normally on a device that already has the speech
    /// assets: `assetInstallationRequest` returns nil and preparation succeeds
    /// without downloading. CLAUDE.md's trap table warns that a silent failure
    /// here makes the first transcription fail with no explanation, which is
    /// why the state is surfaced rather than swallowed.
    func prepareAssets() async {
        guard !assetState.isReady else { return }

        do {
            let locale = await Self.resolveLocale()
            let transcriber = Self.makeTranscriber(locale: locale)
            self.locale = locale

            // ✅ SEAM RESOLVED (S-1) — verified against the shipping
            // Speech.swiftinterface in the macOS 26 SDK (iOS variant). All
            // three names were correct:
            //   AssetInventory.assetInstallationRequest(supporting: [any SpeechModule])
            //     async throws -> AssetInstallationRequest?      (note: Optional)
            //   AssetInstallationRequest: NSObject, ProgressReporting, Sendable
            //     → `.progress` is the ProgressReporting requirement
            //   AssetInstallationRequest.downloadAndInstall() async throws
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                assetState = .preparing(nil)

                let progress = request.progress
                let reporter = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.assetState = .preparing(progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                defer { reporter.cancel() }

                try await request.downloadAndInstall()
            }

            assetState = .ready
        } catch {
            assetState = .failed("Couldn't prepare the speech model. \(error.localizedDescription)")
        }
    }

    /// One transcriber, configured the same way every time.
    ///
    /// `.volatileResults` is what makes words appear *as* you speak rather than
    /// only at the end of a phrase.
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    /// Device locale when its model is available, otherwise en-US.
    private static func resolveLocale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current

        if let match = supported.first(where: {
            $0.language.languageCode == current.language.languageCode
                && $0.region == current.region
        }) {
            return match
        }
        if let language = supported.first(where: {
            $0.language.languageCode == current.language.languageCode
        }) {
            return language
        }
        return Locale(identifier: "en-US")
    }

    // MARK: - Transcribing

    /// Begin transcribing. The stream yields the transcript so far, growing as
    /// results arrive, and finishes when transcription ends.
    func start() async throws -> AsyncStream<String> {
        guard let locale else { throw SpeechInputError.notPrepared }
        guard !isCapturing else { throw SpeechInputError.inputUnavailable }

        // A transcriber is SINGLE-USE. `stop()` calls
        // `finalizeAndFinishThroughEndOfInput()`, which permanently finishes
        // this transcriber's results stream. Handing a finished one to a fresh
        // `SpeechAnalyzer` traps inside the framework on the second turn:
        //
        //     TranscriberCommon.worker.setter
        //     SpeechAnalyzer.setWorkers(for:reusingFrom:preservingFunctionOf:)
        //     SpeechAnalyzer.prepareModulesIfNeeded()
        //
        // Reproduced three times on device. The locale is the durable thing;
        // the transcriber is per-turn.
        let transcriber = Self.makeTranscriber(locale: locale)
        self.transcriber = transcriber

        // With `autoStop` off this is `[transcriber]` and everything downstream
        // is identical to the verified path. Nothing about the detector leaks
        // into the off case.
        let detector = autoStop
            ? SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium),
                             reportResults: true)
            : nil
        self.detector = detector

        let modules: [any SpeechModule] = detector.map { [transcriber, $0] } ?? [transcriber]

        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        // ✅ SEAM RESOLVED (S-2) — verified against the shipping
        // Speech.swiftinterface. Signature is exactly:
        //   static func bestAvailableAudioFormat(compatibleWith: [any SpeechModule])
        //     async -> AVAudioFormat?
        // `async` and Optional, both handled. (A second overload taking
        // `considering naturalFormat:` also exists; not needed here.)
        //
        // The analyser dictates its own format. The iPhone mic runs at 48 kHz,
        // so conversion is mandatory: feeding raw hardware buffers is the
        // failure that produces silence rather than an error.
        // Every module, not just the transcriber — a format the detector cannot
        // accept would fail at `analyzer.start`, after capture is already
        // running.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)

        let (partials, partialsBuilder) = AsyncStream<String>.makeStream()

        resultsTask = Task {
            var finalized = ""
            var volatileText = ""

            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)

                    if result.isFinal {
                        finalized += text
                        volatileText = ""
                    } else {
                        volatileText = text
                    }

                    partialsBuilder.yield(finalized + volatileText)
                }
            } catch {
                // Analyser ended or failed; whatever was finalised still stands.
            }

            partialsBuilder.finish()
            return finalized + volatileText
        }

        if let detector { watchForSilence(detector) }

        try startCapture(converting: analyzerFormat, into: inputBuilder)
        try await analyzer.start(inputSequence: inputSequence)

        return partials
    }

    // MARK: - Auto-stop

    /// Ends the turn once speech has started and then stopped.
    ///
    /// Two tasks rather than one, because the detector's results are ranges
    /// arriving at a cadence this code does not control. Timing a silence off
    /// that cadence would make the threshold depend on how often the framework
    /// happens to report — so the detector only ever records *when speech last
    /// happened*, and a separate clock decides when enough time has passed.
    ///
    /// `lastSpeechAt` starting nil is deliberate: until he has actually said
    /// something there is no silence to measure, so holding the button in a
    /// quiet room never fires.
    private func watchForSilence(_ detector: SpeechDetector) {
        lastSpeechAt = nil

        detectorTask = Task { [weak self] in
            do {
                for try await result in detector.results where result.speechDetected {
                    self?.lastSpeechAt = .now
                }
            } catch {
                // The analyser ended, which `stop()` is already handling.
            }
        }

        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.isCapturing else { return }
                guard let last = self.lastSpeechAt else { continue }

                if .now - last > Self.silenceWindow {
                    self.onSilence?()
                    return
                }
            }
        }
    }

    /// Stop capture, flush the analyser, and return the settled transcript.
    func stop() async -> String {
        guard isCapturing else { return "" }

        // Cancelled before the analyser is finalised, so a late detector result
        // cannot call `onSilence` into a turn that is already ending.
        detectorTask?.cancel()
        silenceTask?.cancel()
        detectorTask = nil
        silenceTask = nil
        lastSpeechAt = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false
        level = 0

        inputBuilder?.finish()
        inputBuilder = nil

        // ✅ SEAM RESOLVED (S-3) — verified against the shipping
        // Speech.swiftinterface. `finalizeAndFinishThroughEndOfInput() async
        // throws` is real and is the correct call here. HANDOVER §5 suspected
        // the name was invented; it is not. `finalizeAndFinish(through: CMTime)`
        // also exists but takes a time, so it is the wrong one for "flush
        // everything". Must happen before reading the results task so trailing
        // final results are included.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()

        let final = await resultsTask?.value ?? ""

        resultsTask = nil
        analyzer = nil
        // Both discarded deliberately: finished, and never to be reused. The
        // detector is assumed single-use for the same reason as the transcriber
        // — nothing says it is not, and reusing the transcriber trapped inside
        // the framework on the second turn.
        transcriber = nil
        detector = nil
        return final
    }

    // MARK: - Capture

    private func startCapture(
        converting analyzerFormat: AVAudioFormat?,
        into builder: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let input = audioEngine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0 else {
            throw SpeechInputError.inputUnavailable
        }

        guard let analyzerFormat else { throw SpeechInputError.converterUnavailable }
        // Correction to HANDOVER §6's first concurrency hatch: this used to be
        // `nonisolated(unsafe) let converter = made`. It isn't needed —
        // `AVAudioConverter` is Sendable in the iOS 26 SDK, and the compiler
        // says so ("'nonisolated(unsafe)' is unnecessary for a constant with
        // 'Sendable' type 'AVAudioConverter'"). The hatch and the local it
        // existed to host are both gone.
        guard let converter = AVAudioConverter(from: hardwareFormat, to: analyzerFormat) else {
            throw SpeechInputError.converterUnavailable
        }

        // `@Sendable` is REQUIRED, and its absence was the second hard crash on
        // device — same fault as `requestRecognitionAccess`, different site.
        //
        // `AVAudioNodeTapBlock` is not `NS_SWIFT_SENDABLE`, so without this the
        // closure inherits `startCapture`'s @MainActor isolation. AVAudioEngine
        // then calls it on its realtime audio queue and the Swift 6 runtime
        // traps on the executor mismatch:
        //
        //     _dispatch_assert_queue_fail
        //     _swift_task_checkIsolatedSwift
        //     closure #1 in SpeechInput.startCapture(converting:into:)
        //     AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform()
        //
        // Marking it @Sendable is what the surrounding code always assumed —
        // it is why the level and conversion helpers are static and why the
        // MainActor hop below is explicit.
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { @Sendable buffer, _ in
            let measured = Self.normalisedLevel(of: buffer)
            Task { @MainActor [weak self] in
                self?.apply(measured)
            }

            guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else {
                return
            }
            builder.yield(AnalyzerInput(buffer: converted))
        }

        audioEngine.prepare()
        try audioEngine.start()
        isCapturing = true
    }

    // `nonisolated` because this is called from the @Sendable audio tap above,
    // off the main actor. It is a pure function over its arguments.
    nonisolated private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        // `AVAudioConverterInputBlock` is @Sendable, so under strict concurrency
        // the block may neither capture a mutable local nor a non-Sendable
        // `AVAudioPCMBuffer`. Both attributes are honest here: `convert` calls
        // the block synchronously, on this thread, before returning, so nothing
        // is actually concurrent and neither value outlives the call.
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let source = buffer
        var conversionError: NSError?

        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }

        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: - Level

    private func apply(_ newValue: Float) {
        // Fast attack, slow release — reads as responsive rather than twitchy.
        level = newValue > level ? newValue : level * 0.75 + newValue * 0.25
    }

    // Also called from the @Sendable audio tap, so it cannot be main-actor
    // isolated. Pure function over the buffer.
    nonisolated private static func normalisedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sumOfSquares += sample * sample
            }
        }

        let rms = (sumOfSquares / Float(frameCount * channelCount)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
