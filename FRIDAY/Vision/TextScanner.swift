import CoreGraphics
import Foundation
import Vision

/// On-device text recognition.
///
/// Free in every sense that matters here: no entitlement, no capability, no
/// network, and `NSCameraUsageDescription` is already in the Info.plist — it was
/// added for a LiveKit phase that never arrived and has been unused since.
///
/// iOS 26's `RecognizeDocumentRequest` understands document *structure* rather
/// than just lines of text, so tables stay tables and lists stay lists. That
/// matters because the output is fed to the language model, and a flattened
/// table becomes noise the moment it loses its shape.
enum TextScanner {
    enum ScanError: LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "That image couldn't be read."
            case .empty: "There's no text in that one."
            }
        }
    }

    /// Pull the text out of an image, preserving structure where the framework
    /// reports it.
    static func text(in image: CGImage) async throws -> String {
        // Verified against the iOS 26 SDK rather than guessed at, after two
        // wrong turns: `perform(on:)` takes a CGImage, URL or CVPixelBuffer —
        // not Data — and the text hangs off
        // `DocumentObservation.document.text.transcript`, where `document` is a
        // `Container` and `text` is a `Container.Text`. Neither the observation
        // nor the container carries `transcript` directly.
        let observations = try await RecognizeDocumentsRequest().perform(on: image)

        let text = observations
            .map(\.document.text.transcript)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw ScanError.empty }
        return text
    }
}
