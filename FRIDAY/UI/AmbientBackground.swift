import SwiftUI

/// Slow ambient field behind the interface.
///
/// Built from radial gradients with no `.blur()` anywhere — blur is the
/// expensive part, and gradients are already soft. Keeps the idle frame cheap.
struct AmbientBackground: View {
    var accent: Color

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
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.9), value: accent)
        .onAppear(perform: startDrift)
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
