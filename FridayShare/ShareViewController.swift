import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Read with FRIDAY" from any app's share sheet.
///
/// **It is entirely self-contained, and that is forced rather than chosen.** An
/// extension hands data to its host app through an App Group, which needs a paid
/// membership to register and, added on a free account, risks provisioning
/// outright — the same wall as D-32 and D-52. So this extension cannot pass a
/// PDF to FRIDAY and let the app do the work. It does the work itself.
///
/// What that costs, stated plainly: `TextScanner` and `PDFReader` are compiled
/// into **both** targets. They are shared source rather than copied text, so
/// they cannot drift, but the extension does carry its own copy of the reading
/// path.
///
/// What it deliberately does **not** carry is the model. Receipt, boarding-pass
/// and business-card extraction all stay in the app. An extension runs under a
/// far tighter memory limit than an app, and loading a ~3B model inside one to
/// save a round trip is how an extension gets killed mid-share — the user would
/// see it vanish, with no error and nothing to retry.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let model = ShareModel { [weak self] in
            self?.finish()
        }

        let host = UIHostingController(rootView: SharedTextView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await model.read(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// Reads whatever was shared, then holds the result for the view.
@MainActor
@Observable
final class ShareModel {
    enum State {
        case reading
        case text(String)
        case failed(String)
    }

    private(set) var state: State = .reading
    let onDone: () -> Void

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    func read(_ items: [NSExtensionItem]) async {
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            // PDFs first: a PDF also conforms to `public.data`, so asking for the
            // image type first would load a document as bytes and fail.
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier),
               let url = await url(of: .pdf, from: provider) {
                await readPDF(at: url)
                return
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data = await imageData(from: provider) {
                await readImage(data)
                return
            }
        }
        state = .failed("I couldn't read what you sent, boss.")
    }

    private func readPDF(at url: URL) async {
        do {
            state = .text(try await PDFReader.text(in: url))
        } catch {
            state = .failed(
                (error as? PDFReader.PDFError)?.errorDescription
                    ?? (error as? TextScanner.ScanError)?.errorDescription
                    ?? "That file wouldn't read, boss."
            )
        }
    }

    private func readImage(_ data: Data) async {
        do {
            state = .text(try await TextScanner.text(in: data))
        } catch {
            state = .failed(
                (error as? TextScanner.ScanError)?.errorDescription
                    ?? "That one wouldn't read, boss."
            )
        }
    }

    /// The shared item is **unwrapped inside the completion handler**, and only
    /// a `Sendable` value crosses back.
    ///
    /// `NSSecureCoding` is not `Sendable`, so returning the item itself and
    /// casting afterwards does not compile — *"sending 'item' risks causing data
    /// races"*. The same discipline as `CNContact` and `CMPedometerData`
    /// elsewhere in this project: take what you need where the callback lands
    /// and carry nothing else out.
    private func url(of type: UTType, from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                continuation.resume(returning: item as? URL)
            }
        }
    }

    /// Images arrive as a URL, a `UIImage` or raw `Data` depending on which app
    /// did the sharing, so all three are handled rather than assuming the one
    /// that happened to be tested.
    private func imageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                let data: Data? = switch item {
                case let url as URL: try? Data(contentsOf: url)
                case let raw as Data: raw
                case let image as UIImage: image.jpegData(compressionQuality: 0.9)
                default: nil
                }
                continuation.resume(returning: data)
            }
        }
    }
}
