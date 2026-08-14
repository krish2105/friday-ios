import FoundationModels
import Observation

/// Whether Apple's on-device language model can actually be used right now,
/// reduced to the cases this app needs to act on.
enum AIStatus: Hashable, Sendable {
    case ready
    case appleIntelligenceOff
    case deviceNotEligible
    case modelDownloading
    case unknown(String)
}

extension AIStatus {
    /// Short label shown in large type.
    var statusMessage: String {
        switch self {
        case .ready: "Ready"
        case .appleIntelligenceOff: "Apple Intelligence Off"
        case .deviceNotEligible: "Device Not Supported"
        case .modelDownloading: "Preparing Model"
        case .unknown: "Unavailable"
        }
    }

    /// One line telling the user how to fix it. `nil` when nothing is wrong.
    var fixInstruction: String? {
        switch self {
        case .ready:
            nil
        case .appleIntelligenceOff:
            "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri."
        case .deviceNotEligible:
            // The real gate is A17 Pro, which means iPhone 15 Pro and newer —
            // not 16 Pro. Owner's call (HANDOVER §9.1): state the accurate
            // floor here, and note in the README that 16 Pro is the only
            // device the app has actually been verified on.
            "This iPhone can't run the on-device model. FRIDAY needs an iPhone 15 Pro or newer."
        case .modelDownloading:
            "The system is still downloading the model. This finishes in the background — try again shortly."
        case .unknown(let detail):
            detail
        }
    }

    var isReady: Bool { self == .ready }
}

/// Checks the on-device model's availability and republishes it to the UI.
@MainActor
@Observable
final class AIAvailability {
    private(set) var status: AIStatus

    init() {
        status = Self.currentStatus()
    }

    /// Re-check. Called when the app becomes active, so toggling Apple
    /// Intelligence in Settings and coming back shows the new state rather
    /// than a stale one cached at launch.
    func refresh() {
        status = Self.currentStatus()
    }

    // MARK: - FoundationModels seam
    //
    // ⚠️ This is the ONLY place in the app that touches FoundationModels.
    //
    // ✅ VERIFIED against the iPhoneOS 26.5 SDK's FoundationModels
    // .swiftinterface. `UnavailableReason` has exactly three cases and all
    // three names below are correct:
    //     case deviceNotEligible
    //     case appleIntelligenceNotEnabled
    //     case modelNotReady
    //
    // CLAUDE.md calls this the highest-risk API surface in the project, and it
    // is — but note the compiler already guards it. A wrong case name here is a
    // build error, not a runtime surprise, so a green build proves this switch.
    //
    // Note: `reason` is intentionally left un-annotated so the compiler infers
    // its type. That way the enum's nesting path — Availability.UnavailableReason
    // vs UnavailableReason — cannot be got wrong here.

    private static func currentStatus() -> AIStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready

        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceOff
            case .modelNotReady:
                return .modelDownloading
            @unknown default:
                return .unknown("Unrecognised availability reason: \(reason)")
            }
        }
    }
}
