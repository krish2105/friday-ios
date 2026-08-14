import AVFoundation
import Foundation
import Observation
import SoundAnalysis

/// What FRIDAY can hear that isn't words.
///
/// Every other ear in this app is pointed at speech. `SoundAnalysis` ships a
/// 303-class classifier on device — enumerated on 2026-08-15 rather than taken
/// from documentation — covering `smoke_detector`, `baby_crying`,
/// `glass_breaking`, `dog_bark`, `siren`, `applause`, `train_horn` and three
/// hundred more. No entitlement, no capability, no network: the same shape as
/// everything else here.
///
/// **Explicitly invoked, never ambient.** It listens when asked and stops itself
/// after `window` seconds. Persistent background listening is the thing iOS will
/// not allow a third-party app to do — the same limit that killed the wake word
/// — and even where it is allowed it is a battery cost nobody agreed to.
///
/// **It answers; it does not alert.** FRIDAY will tell you she heard a smoke
/// detector if you ask what that noise was. She will not watch for one. A
/// safety-critical promise on a general-purpose classifier is a promise this app
/// cannot keep, and half-keeping it is worse than not making it.
@MainActor
@Observable
final class SoundListener {

    /// One thing heard, flattened to a value the moment it arrives.
    ///
    /// `SNClassification` is a non-Sendable ObjC class delivered on the
    /// framework's own queue. Mapping it to this *inside* the observer callback
    /// is the same fix `CNContact`, `CMPedometerData` and `NSSecureCoding` each
    /// needed in earlier stages — three separate occurrences of one lesson.
    struct Heard: Sendable, Equatable {
        let identifier: String
        let confidence: Double

        /// The classifier's identifier as something a person would say.
        ///
        /// Identifiers are snake_case machine labels — `smoke_detector`,
        /// `typing_computer_keyboard`. FRIDAY saying "typing_computer_keyboard"
        /// out loud would break the persona contract in CLAUDE.md as surely as
        /// naming a tool would.
        var spoken: String {
            Self.names[identifier] ?? identifier.replacingOccurrences(of: "_", with: " ")
        }

        /// Only where the mechanical de-underscoring reads badly. The long tail
        /// is left to the general rule rather than transcribed by hand — there
        /// are 303 of them and "dog bark" is already fine.
        private static let names: [String: String] = [
            "smoke_detector": "a smoke alarm",
            "alarm_clock": "an alarm clock",
            "baby_crying": "a baby crying",
            "baby_laughter": "a baby laughing",
            "dog_bark": "a dog barking",
            "dog_howl": "a dog howling",
            "cat_meow": "a cat",
            "cat_purr": "a cat purring",
            "glass_breaking": "breaking glass",
            "glass_clink": "glasses clinking",
            "police_siren": "a police siren",
            "ambulance_siren": "an ambulance",
            "fire_engine_siren": "a fire engine",
            "car_horn": "a car horn",
            "train_horn": "a train horn",
            "toilet_flush": "a toilet flushing",
            "vacuum_cleaner": "a vacuum cleaner",
            "microwave_oven": "a microwave",
            "water_tap_faucet": "a running tap",
            "typing_computer_keyboard": "typing",
            "telephone_bell_ringing": "a phone ringing",
            "wind_rustling_leaves": "wind in the leaves",
            "crying_sobbing": "someone crying",
            "speech": "someone talking",
            "music": "music",
            "silence": "not much at all"
        ]
    }

    /// How long a listen lasts.
    ///
    /// Long enough for a sound to repeat — a doorbell, a bark, a siren passing —
    /// and short enough that nobody is left wondering whether it is still
    /// running. It stops itself; there is no way to leave it on.
    static let window: Int = 12

    /// Below this, the guess is not worth saying out loud.
    ///
    /// Measured on 2026-08-15 against `SNAudioFileAnalyzer`, not picked:
    ///
    /// | Input | Top class | Confidence |
    /// |---|---|---|
    /// | six seconds of digital silence | `music` | **0.248** |
    /// | white noise | `music` | 0.133 |
    /// | 440 Hz sine | `music` / `tuning_fork` | 0.785 / 0.505 |
    ///
    /// The first row is the whole argument. Fed *nothing at all* the classifier
    /// still names a top class and gives it a quarter of its confidence, so a
    /// floor is the only thing standing between "I heard a dog" and "I heard
    /// nothing and said dog anyway". This sits above that with margin.
    ///
    /// The sine is not a false positive and was not treated as one — a 440 Hz
    /// tone genuinely is a tuning fork, and reading it as noise would have set
    /// the floor far too high.
    static let confidenceFloor: Double = 0.35

    private(set) var isListening = false

    private let audioEngine = AVAudioEngine()
    private var tally: [String: Double] = [:]

    /// Listens for `window` seconds and reports what it heard, best first.
    ///
    /// Returns an empty array when nothing cleared the floor, which is a real
    /// answer and gets its own line rather than being dressed up as a guess.
    func listen() async -> [Heard] {
        guard !isListening else { return [] }
        guard await AudioSessionManager.requestMicrophoneAccess() else { return [] }

        tally = [:]
        isListening = true
        defer { isListening = false }

        do {
            try start()
        } catch {
            stop()
            return []
        }

        try? await Task.sleep(for: .seconds(Self.window))
        stop()

        // The best confidence each sound reached at any point in the window,
        // not the average. A dog that barks twice in twelve seconds is a dog;
        // averaging it against ten seconds of room tone would bury it.
        return tally
            .filter { $0.value >= Self.confidenceFloor }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { Heard(identifier: $0.key, confidence: $0.value) }
    }

    private func start() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw SoundListenerError.inputUnavailable
        }

        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else {
            throw SoundListenerError.classifierUnavailable
        }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = SoundObserver { [weak self] heard in
            Task { @MainActor in self?.record(heard) }
        }
        try analyzer.add(request, withObserver: observer)

        // Held past the end of this method by the tap closure and the analyzer
        // respectively; without these the observer deallocates immediately and
        // no result ever arrives.
        self.observer = observer
        let box = AnalyzerBox(analyzer)
        self.analyzerBox = box

        // `@Sendable` is REQUIRED here, exactly as in `SpeechInput.startCapture`,
        // and its absence there was a hard crash on device: `AVAudioNodeTapBlock`
        // is not `NS_SWIFT_SENDABLE`, so without it the closure inherits this
        // method's @MainActor isolation and the Swift 6 runtime traps on the
        // executor mismatch when the audio queue calls it.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            // The frame counter lives *inside* the box rather than being a local
            // captured here. Captured, it is a `var` mutated from the audio
            // thread — "mutation of captured var in concurrently-executing code",
            // which is a real race and not a pedantic one. The box already owns
            // the one documented unsafety in this file; the counter belongs with
            // it rather than as a second, undocumented one.
            box.analyze(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        analyzerBox?.complete()
        analyzerBox = nil
        observer = nil
    }

    private func record(_ heard: Heard) {
        tally[heard.identifier] = max(tally[heard.identifier] ?? 0, heard.confidence)
    }

    @ObservationIgnored private var observer: SoundObserver?
    @ObservationIgnored private var analyzerBox: AnalyzerBox?

    enum SoundListenerError: Error {
        case inputUnavailable
        case classifierUnavailable
    }
}

/// Lets the realtime tap reach the analyser.
///
/// `SNAudioStreamAnalyzer` is not `Sendable`, and the tap block must be
/// `@Sendable`, so the two cannot meet without a hatch. This one is justified by
/// Apple's own header rather than by convenience — `SNAnalyzer.h` on
/// `analyzeAudioBuffer:atAudioFramePosition:` states the method is *"not safe to
/// call from a realtime audio context but may be called from lower priority
/// threads (i.e. AVAudioEngine tap callback or AudioQueue callback)"*. A tap
/// callback is precisely the sanctioned case.
///
/// Kept as a named box rather than `nonisolated(unsafe)` at the use site so the
/// unsafety has one address and one explanation.
private final class AnalyzerBox: @unchecked Sendable {
    private let analyzer: SNAudioStreamAnalyzer

    /// Where in the stream we are, in frames.
    ///
    /// The header requires a *monotonically increasing* sample timestamp and
    /// says the analyser may reset its internal state if the timeline jumps — so
    /// this cannot simply be zero every buffer. It lives here because a tap
    /// callback is serial: `AVAudioEngine` delivers buffers one at a time from a
    /// single thread, so there is exactly one writer. That is the same guarantee
    /// the `@unchecked` above rests on, and keeping the counter beside it means
    /// the file has one unsafe thing rather than two.
    private var frame: AVAudioFramePosition = 0

    init(_ analyzer: SNAudioStreamAnalyzer) {
        self.analyzer = analyzer
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        analyzer.analyze(buffer, atAudioFramePosition: frame)
        frame += AVAudioFramePosition(buffer.frameLength)
    }

    func complete() {
        analyzer.completeAnalysis()
    }
}

/// Receives classifications on the framework's queue.
///
/// A separate non-isolated `NSObject` holding the work — HANDOVER §7's pattern
/// rather than a preference, and the same shape as `NotificationResponder`.
/// `SNResultsObserving` is called by the system on its own terms, and every
/// runtime crash this project has had was a `@MainActor` type's closure
/// inheriting isolation and then being invoked elsewhere.
///
/// Two naming traps here, both paid for rather than reasoned about:
///
/// - The ObjC selector is `request:didProduceResult:`, but Swift **renames** it
///   to `request(_:didProduce:)`. Writing the header's spelling fails to compile
///   with *"has been renamed to 'request(_:didProduce:)'"* — which is the good
///   case, because it is the protocol's one required member.
/// - `didFailWithError` and `requestDidComplete` are `@optional`, so a
///   misspelling of *those* compiles with only a warning. That is exactly the
///   VisionKit trap this project has already been caught by once, where a
///   scanner failure silently had no handler.
private final class SoundObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let onHeard: @Sendable (SoundListener.Heard) -> Void

    init(onHeard: @escaping @Sendable (SoundListener.Heard) -> Void) {
        self.onHeard = onHeard
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let classification = result as? SNClassificationResult else { return }

        // Mapped to a Sendable value *here*, inside the callback, before it can
        // cross an isolation boundary.
        for candidate in classification.classifications.prefix(3) {
            onHeard(SoundListener.Heard(identifier: candidate.identifier,
                                        confidence: candidate.confidence))
        }
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        // Nothing to recover: the window closes on its own and an empty tally
        // already has a line FRIDAY can say.
    }
}
