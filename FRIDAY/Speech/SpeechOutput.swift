import AVFoundation
import Observation

/// Bridges `AVSpeechSynthesizer`'s delegate callbacks back to Swift concurrency.
///
/// Kept separate from `SpeechOutput` so the observable type doesn't have to be
/// an `NSObject`.
private final class SynthesisObserver: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let ended: @Sendable () -> Void

    init(ended: @escaping @Sendable () -> Void) {
        self.ended = ended
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        ended()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        ended()
    }
}

/// FRIDAY's voice.
///
/// Note on quality: Siri's voices are not available to third-party apps
/// through `AVSpeechSynthesizer` — that's an Apple restriction, not a gap here.
/// The best obtainable are `.premium` and `.enhanced` voices, which the user
/// must download themselves in Settings. There is also no API to list voices
/// that are *available* to download but not yet installed, so the most the app
/// can do is notice it only has default-quality voices and say where to get
/// better ones.
@MainActor
@Observable
final class SpeechOutput {
    private(set) var isSpeaking = false

    /// Slightly under `AVSpeechUtteranceDefaultSpeechRate` (0.5) — a composed
    /// aide doesn't rush.
    static let composedRate: Float = 0.46

    var speakReplies: Bool {
        didSet { defaults.set(speakReplies, forKey: Key.speakReplies) }
    }

    var rate: Float {
        didSet { defaults.set(rate, forKey: Key.rate) }
    }

    /// `nil` means "pick the best installed voice automatically".
    var voiceIdentifier: String? {
        didSet { defaults.set(voiceIdentifier, forKey: Key.voice) }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let defaults = UserDefaults.standard
    private var observer: SynthesisObserver?
    private var pending: CheckedContinuation<Void, Never>?

    private enum Key {
        static let speakReplies = "friday.speakReplies"
        static let rate = "friday.speechRate"
        static let voice = "friday.voiceIdentifier"
    }

    init() {
        speakReplies = defaults.object(forKey: Key.speakReplies) as? Bool ?? true
        rate = defaults.object(forKey: Key.rate) as? Float ?? Self.composedRate
        voiceIdentifier = defaults.string(forKey: Key.voice)

        let observer = SynthesisObserver { [weak self] in
            Task { @MainActor in self?.settle() }
        }
        self.observer = observer
        synthesizer.delegate = observer
    }

    // MARK: - Speaking

    /// Speak, returning only once playback has finished or been cut off.
    func speak(_ text: String) async {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard speakReplies, !line.isEmpty else { return }

        stop()

        let utterance = AVSpeechUtterance(string: line)
        // The voice is chosen from the script of the text itself, so nothing has
        // to thread "this turn is in Hindi" down from the engine. An English
        // voice reading Devanagari produces nothing usable.
        utterance.voice = resolvedVoice(for: Bilingual.tongue(of: line))
        utterance.rate = rate

        isSpeaking = true
        await withCheckedContinuation { continuation in
            pending = continuation
            synthesizer.speak(utterance)
        }
    }

    /// Cut playback off immediately. This is barge-in.
    func stop() {
        guard synthesizer.isSpeaking || pending != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
        settle()
    }

    /// Resumes whoever is awaiting `speak`. Safe to call more than once —
    /// `stop()` and the cancel callback both land here.
    private func settle() {
        isSpeaking = false
        let continuation = pending
        pending = nil
        continuation?.resume()
    }

    // MARK: - Voices

    /// English voices installed on this device, best quality first.
    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { left, right in
                let leftRank = Self.rank(left.quality)
                let rightRank = Self.rank(right.quality)
                if leftRank != rightRank { return leftRank > rightRank }
                return left.name < right.name
            }
    }

    /// False when the device only has default-quality voices, which is the cue
    /// to tell the user where better ones live.
    var hasHighQualityVoice: Bool {
        availableVoices.contains { $0.quality != .default }
    }

    /// The voice that will actually be used.
    ///
    /// The chosen-voice preference only applies to English. It is picked from a
    /// list of English voices in Settings, and honouring it for a Hindi line
    /// would have an English voice sounding out Devanagari.
    func resolvedVoice(for tongue: Tongue = .english) -> AVSpeechSynthesisVoice? {
        if tongue == .hindi {
            return bestVoice(matching: "hi") ?? AVSpeechSynthesisVoice(language: "hi-IN")
        }
        if let voiceIdentifier, let chosen = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return chosen
        }
        return bestInstalledVoice()
    }

    /// Highest-quality installed voice for a language code, if there is one.
    ///
    /// `Lekha` (`hi-IN`) ships installed, so Hindi normally resolves here. There
    /// is no in-app way to offer a download for a better one, same as English.
    private func bestVoice(matching code: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(code) }
            .max { Self.rank($0.quality) < Self.rank($1.quality) }
    }

    private func bestInstalledVoice() -> AVSpeechSynthesisVoice? {
        let voices = availableVoices
        guard !voices.isEmpty else { return AVSpeechSynthesisVoice(language: "en-US") }

        // Among equally good voices, prefer one matching the device region.
        if let region = Locale.current.region?.identifier {
            let localMatch = voices.first { $0.language.hasSuffix(region) }
            if let localMatch, Self.rank(localMatch.quality) == Self.rank(voices[0].quality) {
                return localMatch
            }
        }
        return voices[0]
    }

    static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: 3
        case .enhanced: 2
        case .default: 1
        @unknown default: 0
        }
    }

    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        case .default: "Standard"
        @unknown default: "Unknown"
        }
    }
}
