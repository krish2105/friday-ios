import SwiftUI

/// Slow ambient field behind the interface.
///
/// Built from radial gradients with no `.blur()` anywhere — blur is the
/// expensive part, and gradients are already soft. Keeps the idle frame cheap.
struct AmbientBackground: View {
    var accent: Color

    /// Drift only while FRIDAY is actually doing something.
    ///
    /// Measured on device: idle CPU was 8% in a Release build against a <5%
    /// budget, with the orb already innocent — no `Canvas` exists at idle
    /// (D-38). The cost is this view meeting Liquid Glass. Three glass surfaces
    /// sit on top of it, and glass re-samples its backdrop every frame; while
    /// these blobs drift, that backdrop never stops moving, so the blur can
    /// never be cached. D-38 budgeted the orb and never accounted for the
    /// interaction.
    ///
    /// Holding still at rest costs nothing visually — the field is slow enough
    /// that it reads as static anyway — and it lets the compositor cache.
    var isAnimating: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [FridayTheme.groundRaised, FridayTheme.ground],
                startPoint: .top,
                endPoint: .bottom
            )

            blob(accent.opacity(0.32), size: 470)
                .offset(x: drift ? -70 : -150, y: drift ? -280 : -210)

            blob(FridayTheme.amber.opacity(0.20), size: 400)
                .offset(x: drift ? 160 : 100, y: drift ? 240 : 320)

            blob(accent.opacity(0.14), size: 320)
                .offset(x: drift ? 130 : 50, y: drift ? -40 : 30)
        }
        // Load-bearing. The blobs have fixed frames up to 470pt, and a ZStack
        // sizes to its largest child — so without this the background reported
        // 470pt wide on a 393pt screen. ContentView's outer ZStack adopted that
        // width and centred the interface inside it, clipping ~38pt off every
        // edge: the header, every bubble and the footer were all cut off.
        //
        // This pins the reported size to whatever is proposed. The blobs still
        // render past the bounds, which is the intended soft bleed.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.9), value: accent)
        .onAppear { if isAnimating { startDrift() } }
        .onChange(of: isAnimating) { _, active in
            active ? startDrift() : stopDrift()
        }
    }

    /// A finite animation replaces the `repeatForever` one, which is the only
    /// way to actually stop it.
    private func stopDrift() {
        withAnimation(.easeInOut(duration: 0.8)) { drift = false }
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
    }

    private func startDrift() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) {
            drift = true
        }
    }
}
