import CoreGraphics
import Foundation
import PDFKit

/// Reads a PDF, by whichever of the two routes the file actually needs.
///
/// A PDF is either **text with a layout** or **pictures of text**, and the two
/// need opposite treatment. A born-digital invoice carries its characters, so
/// asking Vision to look at a picture of them would throw away perfect data and
/// introduce OCR errors into something that had none. A scan has no characters
/// at all and needs the full `TextScanner` pass.
///
/// So the text layer is tried first and OCR is the fallback, per page — a PDF
/// can be a mix, which is exactly what a signed contract with a scanned
/// signature page is.
enum PDFReader {

    enum PDFError: LocalizedError {
        case unreadable
        case tooLong

        var errorDescription: String? {
            switch self {
            case .unreadable: "I couldn't open that file."
            case .tooLong: "That document's too long for me to take in one go."
            }
        }
    }

    /// Pages beyond this are not read.
    ///
    /// Each page beyond the first few adds seconds of OCR for a model that can
    /// only hold ~4,096 tokens anyway — so a 200-page manual would spend a
    /// minute producing something that cannot fit. Refusing is honest; silently
    /// reading the first eight and summarising as though it were the whole
    /// document is not.
    static let pageLimit = 8

    static func text(in url: URL) async throws -> String {
        // A file from the document picker lives outside the sandbox and has to
        // be opened explicitly. Without this the URL reads as missing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: url) else { throw PDFError.unreadable }
        guard document.pageCount <= pageLimit else { throw PDFError.tooLong }

        var pages: [String] = []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }

            // The text layer, when there is one.
            if let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                pages.append(text)
                continue
            }

            // No characters on this page — it is a picture. Render it and read
            // it the same way a photograph is read.
            if let image = render(page),
               let text = try? await TextScanner.text(in: image) {
                pages.append(text)
            }
        }

        let joined = pages.joined(separator: "\n\n")
        guard !joined.isEmpty else { throw TextScanner.ScanError.empty }
        return joined
    }

    /// A page as a `CGImage`, at twice its natural size.
    ///
    /// Rendering at 1× gives roughly 72 dpi, which is below what document
    /// recognition needs for body text. 2× is about 144 dpi and reads reliably
    /// without making the image large enough to be slow.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // White, because a PDF page is paper and the context starts transparent
        // — which recognition reads as black text on black.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)

        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
