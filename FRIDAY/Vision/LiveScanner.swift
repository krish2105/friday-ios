import SwiftUI
import VisionKit

/// Live camera recognition — point at a code or a line of text and tap it.
///
/// Distinct from `DocumentCamera` rather than a duplicate of it, and the split
/// is by what you are looking at. A page wants a shutter, edge detection and
/// perspective correction; a QR code on a poster or a line on a shop sign wants
/// none of that and would be actively hindered by all three. This is the
/// point-and-tap half.
///
/// Nothing is captured until a tap. `didTapOn` is the only route out, so the
/// camera can be open without anything being read, which is the right default
/// for a viewfinder pointed at the world.
struct LiveScanner: UIViewControllerRepresentable {
    /// The tapped item — a barcode payload, or a line of recognised text.
    let onRecognise: (String, Bool) -> Void
    let onCancel: () -> Void

    /// False in the Simulator and on hardware without the Neural Engine for it.
    /// `isSupported` is the device; `isAvailable` also accounts for the camera
    /// being restricted, so both are asked.
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(), .text()],
            qualityLevel: .balanced,
            // One at a time, highlighted. Multiples turn a shop sign into a
            // wall of boxes and make the thing you want harder to hit.
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        // `startScanning` throws when the camera is unavailable — restricted by
        // Screen Time, or in use elsewhere. Failing quietly leaves a black
        // rectangle, so it is reported as a cancellation and FRIDAY says
        // nothing rather than something wrong.
        if !context.coordinator.isScanning {
            do {
                try scanner.startScanning()
                context.coordinator.isScanning = true
            } catch {
                onCancel()
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognise: onRecognise)
    }

    /// The delegate is a separate object rather than the `View` — HANDOVER §7's
    /// pattern, and the same one `DocumentCamera` uses.
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var isScanning = false
        private let onRecognise: (String, Bool) -> Void

        init(onRecognise: @escaping (String, Bool) -> Void) {
            self.onRecognise = onRecognise
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            switch item {
            case .barcode(let barcode):
                guard let payload = barcode.payloadStringValue, !payload.isEmpty else { return }
                onRecognise(payload, true)
            case .text(let text):
                guard !text.transcript.isEmpty else { return }
                onRecognise(text.transcript, false)
            @unknown default:
                break
            }
        }
    }
}
