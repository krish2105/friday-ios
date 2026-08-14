import SwiftUI

/// Title, model status, and the way into Settings.
///
/// Pulled out of `ContentView` because it renders from `status` alone and needs
/// nothing else — which is the test for whether a view deserves to be its own
/// file.
struct StatusHeader: View {
    var status: AIStatus
    var onSettings: () -> Void
    var onCapabilities: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(FridayTheme.amber)
                .frame(width: 5, height: 5)

            // Both scale down rather than truncate: the title plus the chip sit
            // close to the available width, and at large Dynamic Type an
            // ellipsis here would eat the product's own name.
            Text("F.R.I.D.A.Y.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tracking(4.2)
                .foregroundStyle(FridayTheme.textPrimary.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 4)

            if status.isReady {
                statusChip
            }

            headerButton("questionmark.circle", label: "What FRIDAY can do", action: onCapabilities)
            headerButton("gearshape.fill", label: "Settings", action: onSettings)
        }
        .onAppear { pulsing = true }
    }

    private func headerButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(FridayTheme.textSecondary)
                // 34pt visually, 44pt to the finger — the visual size is what
                // fits the header, the hit area is what the HIG requires.
                .frame(width: 34, height: 34)
                .glassSurface(cornerRadius: 17)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var statusChip: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status.accent)
                .frame(width: 6, height: 6)
                // Static shadow, animated scale. Animating `radius`
                // re-rasterises the blur every frame forever, for a 6pt dot
                // nobody is looking at — one of the three animations D-50
                // found running on an idle screen.
                .shadow(color: status.accent.opacity(0.9), radius: 3)
                .scaleEffect(pulsing ? 1.2 : 0.9)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.7).repeatForever(autoreverses: true),
                    value: pulsing
                )

            Text(status.badge)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(status.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(status.accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(status.accent.opacity(0.28), lineWidth: 1))
        .accessibilityLabel("Model status: \(status.badge)")
    }
}

/// The red card shown when the model cannot run.
struct FaultCard: View {
    var status: AIStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status.statusMessage)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(FridayTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let fix = status.fixInstruction {
                Text(fix)
                    .font(.system(size: 13.5, weight: .regular, design: .rounded))
                    .foregroundStyle(FridayTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }
}

/// The transient strip between the conversation and the input.
///
/// Two states that are never both true, so they share one slot rather than
/// stacking — the same reasoning as `ActionSlot`, at a smaller scale. Nothing
/// renders when neither applies, so at rest it occupies no space and, more to
/// the point, runs no animation.
struct StatusStrip: View {
    var assetState: SpeechAssetState
    var isListening: Bool
    var liveTranscript: String

    var body: some View {
        if case .preparing(let fraction) = assetState {
            downloading(fraction)
        } else if isListening {
            transcript
        }
    }

    // The speech model is fetched by the system on first use. CLAUDE.md's trap
    // table calls this out: without a visible state, the first transcription
    // just silently fails.
    private func downloading(_ fraction: Double?) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(FridayTheme.downloading)

            Text(fraction.map { "Downloading speech model… \(Int($0 * 100))%" }
                 ?? "Downloading speech model…")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(FridayTheme.downloading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(FridayTheme.downloading.opacity(0.12)))
        .overlay(Capsule().strokeBorder(FridayTheme.downloading.opacity(0.3), lineWidth: 1))
    }

    private var transcript: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(FridayTheme.amber)
                .frame(width: 5, height: 5)

            Text(liveTranscript.isEmpty ? "Listening…" : liveTranscript)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(FridayTheme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .accessibilityLabel("Listening")
        .accessibilityValue(liveTranscript)
    }
}
