import AVFoundation
import Observation

/// Owns the app's `AVAudioSession`.
///
/// Lives for the lifetime of the app: it is created once by `FridayEngine` and
/// never torn down, which is why interruption observation is started in `init`
/// and never removed. A `deinit` that touched main-actor state would fight
/// Swift 6 isolation for no benefit.
@MainActor
@Observable
final class AudioSessionManager {
    /// What the system did to our audio session out from under us.
    enum Interruption: Equatable, Sendable {
        /// A phone call (or similar) took the session. Capture has stopped.
        case began
        /// The interruption finished. `shouldResume` is the system's hint that
        /// it is appropriate to start again.
        case ended(shouldResume: Bool)
    }

    private(set) var isActive = false
    private(set) var lastInterruption: Interruption?

    /// Set by whoever is capturing audio so it can tear down cleanly.
    var onInterruption: ((Interruption) -> Void)?

    private var observer: (any NSObjectProtocol)?

    init() {
        observeInterruptions()
    }

    // MARK: - Permission

    /// Microphone permission. Returns `false` if the user has denied it.
    static func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Lifecycle

    /// Configure for voice capture and go active.
    ///
    /// `.playAndRecord` + `.voiceChat` is the combination that lets the system
    /// apply its voice-processing chain — echo cancellation matters here,
    /// because Session 4 adds TTS and the mic must not hear FRIDAY herself.
    func activate() throws {
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.duckOthers, .defaultToSpeaker]
        )
        try session.setActive(true)
        isActive = true
    }

    /// Release the session so other audio can resume.
    func deactivate() throws {
        guard isActive else { return }
        try AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        isActive = false
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Pull only Sendable primitives out of the notification before
            // hopping — `Notification` itself is not Sendable under Swift 6.
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt

            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }

        switch type {
        case .began:
            // The system has already stopped our capture. Reflect that.
            isActive = false
            emit(.began)

        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            emit(.ended(shouldResume: options.contains(.shouldResume)))

        @unknown default:
            break
        }
    }

    private func emit(_ interruption: Interruption) {
        lastInterruption = interruption
        onInterruption?(interruption)
    }
}
