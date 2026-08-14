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
        // Verified against the iOS 26 SDK rather than guessed at: the text hangs
        // off `DocumentObservation.document.text.transcript`, where `document`
        // is a `Container` and `text` is a `Container.Text`. Neither the
        // observation nor the container carries `transcript` directly.
        try transcript(of: try await RecognizeDocumentsRequest().perform(on: image))
    }

    /// Pull the text out of encoded image data — what the photo picker hands
    /// back, and what a captured photo serialises to.
    ///
    /// This corrects the stage 1 commit message, which said `perform(on:)` does
    /// not take `Data`. It does: `iPhoneOS26.5.sdk`'s `Vision.swiftinterface`
    /// declares the overload on `ImageProcessingRequest` alongside the CGImage
    /// one, with the same defaulted `orientation:`.
    ///
    /// It is the right entry point for a picked photo, and not merely a shorter
    /// one. A portrait iPhone photo is stored as *landscape pixels plus an EXIF
    /// orientation tag*; `UIImage(data:)?.cgImage` throws the tag away, so going
    /// through CGImage would hand Vision a sideways page and quietly cost most
    /// of the recognition. Given the container, Vision reads the orientation
    /// itself.
    static func text(in data: Data) async throws -> String {
        try transcript(of: try await RecognizeDocumentsRequest().perform(on: data))
    }

    /// Several pages from one scan, read in order and kept as a single document.
    ///
    /// A page that reads as blank is skipped rather than failing the scan — the
    /// document camera will happily capture a cover sheet or a blank verso, and
    /// losing four good pages to one empty one would be a poor trade.
    static func text(in pages: [Data]) async throws -> String {
        guard !pages.isEmpty else { throw ScanError.unreadable }

        var found: [String] = []
        for page in pages {
            if let text = try? await text(in: page) { found.append(text) }
        }

        let joined = found.joined(separator: "\n\n")
        guard !joined.isEmpty else { throw ScanError.empty }
        return joined
    }

    private static func transcript(of observations: [DocumentObservation]) throws -> String {
        // Through `DocumentStructure` rather than straight to `.transcript`,
        // which is what the doc comment above has promised since stage 1 and
        // what the code did not do. A page with no tables and no lists comes
        // back byte-identical to the old flattening, so every earlier stage is
        // reading exactly what it read before.
        let text = observations
            .map { DocumentStructure.transcript(of: $0.document) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw ScanError.empty }
        return text
    }
}
