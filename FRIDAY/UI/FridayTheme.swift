import SwiftUI

/// Design tokens. Stark palette: deep charcoal ground, amber/gold accent.
/// Deliberately not blue — this should not read as a Siri clone.
enum FridayTheme {
    // Ground
    static let ground = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let groundRaised = Color(red: 0.086, green: 0.094, blue: 0.110)

    // Brand
    static let amber = Color(red: 1.000, green: 0.702, blue: 0.231)
    static let amberLight = Color(red: 1.000, green: 0.831, blue: 0.510)

    // State
    static let ready = Color(red: 0.353, green: 0.918, blue: 0.600)
    static let downloading = Color(red: 1.000, green: 0.663, blue: 0.251)
    static let fault = Color(red: 1.000, green: 0.400, blue: 0.384)

    // Type
    static let textPrimary = Color(white: 0.965)
    static let textSecondary = Color(white: 0.640)
}

extension AIStatus {
    /// Green ready, orange downloading, red otherwise.
    var accent: Color {
        switch self {
        case .ready: FridayTheme.ready
        case .modelDownloading: FridayTheme.downloading
        case .appleIntelligenceOff, .deviceNotEligible, .unknown: FridayTheme.fault
        }
    }

    /// Short uppercase tag shown in the pill.
    var badge: String {
        switch self {
        case .ready: "ON DEVICE MODEL"
        case .modelDownloading: "DOWNLOADING"
        case .appleIntelligenceOff: "ACTION NEEDED"
        case .deviceNotEligible: "UNSUPPORTED"
        case .unknown: "UNKNOWN"
        }
    }
}

/// FRIDAY's mood for a turn, from the model's `tone` field.
///
/// The model returns free text, so anything unrecognised settles to `.calm`
/// rather than failing — a stray word must never break the UI.
enum FridayTone: String, Sendable {
    case calm
    case alert
    case amused
    case concerned

    init(_ raw: String?) {
        let key = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = FridayTone(rawValue: key) ?? .calm
    }

    var color: Color {
        switch self {
        case .calm: FridayTheme.amber
        case .alert: FridayTheme.downloading
        case .amused: FridayTheme.amberLight
        case .concerned: FridayTheme.fault
        }
    }
}
