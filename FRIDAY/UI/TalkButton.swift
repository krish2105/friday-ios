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
    /// 168 as the empty-state hero, 104 once a conversation needs the room.
    var diameter: CGFloat = 104
    /// Lets the orb *travel* between the two layouts instead of one
    /// disappearing and another appearing somewhere else. The orb is the one
    /// element that is FRIDAY rather than a control, so it should move rather
    /// than be replaced.
    var namespace: Namespace.ID?
    var onPress: () -> Void
    var onRelease: () -> Void

    @State private var isPressed = false

    private var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    var body: some View {
        OrbView(state: state, level: level, diameter: diameter)
            .frame(width: diameter, height: diameter)
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
            .modifier(TravellingOrb(namespace: namespace))
            .accessibilityLabel("Hold to talk")
            .accessibilityHint(isListening ? "Listening. Release to finish." : "Press and hold to speak to FRIDAY.")
            .accessibilityAddTraits(.isButton)
    }
}

/// Applies `matchedGeometryEffect` only when a namespace was supplied.
///
/// A separate modifier because the effect cannot be applied conditionally
/// inline — `if let` inside a view builder produces two different types, and
/// SwiftUI would treat them as different views, which is exactly the identity
/// break the effect exists to prevent.
private struct TravellingOrb: ViewModifier {
    var namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "friday.orb", in: namespace)
        } else {
            content
        }
    }
}
