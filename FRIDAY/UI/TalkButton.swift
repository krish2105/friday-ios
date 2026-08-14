import SwiftUI

/// Push-to-talk control. The orb *is* the button — one focal element rather
/// than a control sitting next to a decoration.
///
/// Press feedback comes from Liquid Glass's `.interactive()` so it matches
/// every other iOS 26 control. Amplitude reaction lives in `OrbView`.
struct TalkButton: View {
    var state: FridayState
    /// Live input level, 0…1.
    var level: Float
    var onPress: () -> Void
    var onRelease: () -> Void

    @State private var isPressed = false

    private var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    var body: some View {
        OrbView(state: state, level: level, diameter: 104)
            .frame(width: 104, height: 104)
            // Tinting the single call-to-action is the selective use the
            // Liquid Glass guidance endorses.
            .glassEffect(
                .regular
                    .tint(FridayTheme.amber.opacity(isListening ? 0.40 : 0.14))
                    .interactive(),
                in: Circle()
            )
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
            .accessibilityLabel("Hold to talk")
            .accessibilityHint(isListening ? "Listening. Release to finish." : "Press and hold to speak to FRIDAY.")
            .accessibilityAddTraits(.isButton)
    }
}
