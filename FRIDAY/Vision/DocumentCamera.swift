import SwiftUI
import VisionKit

/// Live camera capture with a preview, for reading something in front of you.
///
/// This is Apple's document scanner rather than a hand-built `AVCaptureSession`,
/// and the reason is accuracy before it is effort. The scanner finds the page
/// edges and corrects the perspective before it hands the image over, so a page
/// photographed at an angle arrives flat — and `RecognizeDocumentsRequest` reads
/// a flat page far better than a trapezoid one, which is the whole point of the
/// feature. Edge detection, auto-capture, the torch and multi-page all come with
/// it.
///
/// The cost is that the chrome is Apple's, not FRIDAY's glass. A bespoke capture
/// UI would be roughly five times this much code, would have to re-earn the
/// perspective correction, and is a drop-in replacement here if that trade ever
/// stops being worth it.
///
/// Nothing here needs a capability or an entitlement — only the camera usage
/// string, which the Info.plist has carried since a LiveKit phase that never
/// arrived. On a free account that matters (D-32, D-46, D-52).
struct DocumentCamera: UIViewControllerRepresentable {
    /// One JPEG per page, in order. Empty if he backed out, or if the scanner
    /// itself failed — neither is worth a line from FRIDAY.
    let onFinish: ([Data]) -> Void

    /// False in the Simulator and anywhere without a usable camera, which is the
    /// cue to fall back to the photo library rather than present a black screen.
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    /// The delegate is a separate object rather than the `View`, which is
    /// HANDOVER §7's pattern: both runtime crashes this project has had were a
    /// `@MainActor` type's closure inheriting isolation and then being invoked
    /// somewhere else. `SpeechOutput` and `WeatherTool` are safe for exactly
    /// this reason.
    ///
    /// One seam worth recording: VisionKit's `apinotes` in the iOS 26.5 SDK say
    /// `didFailWithError:` is renamed to `documentCameraViewController(_:didFailWith:)`,
    /// and that is wrong for this target — the compiler wants the unabbreviated
    /// `didFailWithError:`, and the shortened form silently fails to satisfy the
    /// requirement, leaving a scanner failure with no handler at all. It warns
    /// rather than errors because the requirement is optional. Reading the
    /// header was not sufficient here; the compiler was the authority.
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: ([Data]) -> Void

        init(onFinish: @escaping ([Data]) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // JPEG, not PNG. `pngData()` writes the backing CGImage and drops
            // `imageOrientation` on the floor; `jpegData` records it as EXIF,
            // which is precisely what `TextScanner` hands to Vision so the page
            // is read the right way up.
            let pages = (0..<scan.pageCount).compactMap {
                scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9)
            }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: any Error
        ) {
            onFinish([])
        }
    }
}
