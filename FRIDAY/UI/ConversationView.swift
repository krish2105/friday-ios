import SwiftUI

/// Scrolling transcript. Boss on the right, FRIDAY on the left.
struct ConversationView: View {
    var turns: [ConversationTurn]
    /// Reply text as it streams in, shown in the in-flight bubble.
    var streamingText: String
    var isThinking: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if turns.isEmpty {
                        emptyState
                    }

                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        TurnBubble(
                            turn: turn,
                            displayText: text(for: turn, isLast: index == turns.count - 1),
                            isAwaiting: isAwaiting(turn, isLast: index == turns.count - 1)
                        )
                        .id(turn.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: turns.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: streamingText) { _, _ in scrollToEnd(proxy) }
        }
    }

    private var emptyState: some View {
        Text("Standing by, boss.")
            .font(.system(size: 16, weight: .regular, design: .rounded))
            .foregroundStyle(FridayTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private func text(for turn: ConversationTurn, isLast: Bool) -> String {
        guard turn.isFriday, turn.text.isEmpty, isLast, isThinking else {
            return turn.text
        }
        return streamingText
    }

    /// Whether this turn is the one being waited on.
    ///
    /// It used to render a literal "…" in a bubble, which at one character wide
    /// collapsed into a small square that read as a broken element rather than
    /// as waiting. A turn with nothing in it yet needs a *shape*, not a glyph.
    private func isAwaiting(_ turn: ConversationTurn, isLast: Bool) -> Bool {
        turn.isFriday && turn.text.isEmpty && isLast && isThinking && streamingText.isEmpty
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = turns.last else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

/// One bubble. FRIDAY's is tinted by the mood the model reported.
private struct TurnBubble: View {
    var turn: ConversationTurn
    var displayText: String
    var isAwaiting = false

    private var tone: FridayTone { FridayTone(turn.tone) }

    var body: some View {
        HStack {
            if turn.isFriday {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if isAwaiting {
            ThinkingDots(tint: tone.color)
        } else if turn.kind == .quoted {
            quotation
        } else {
            speech
        }
    }

    private var speech: some View {
        Text(displayText)
            .font(.system(size: 16, weight: .regular, design: .rounded))
            .foregroundStyle(FridayTheme.textPrimary)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(turn.isFriday ? tone.color.opacity(0.11) : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        turn.isFriday ? tone.color.opacity(0.34) : Color.white.opacity(0.13),
                        lineWidth: 1
                    )
            )
            .accessibilityLabel(turn.isFriday ? "FRIDAY said" : "You said")
            .accessibilityValue(displayText)
    }

    /// Words off a page, not out of her mouth.
    ///
    /// A leading rule and no tone tint, because tone is *her* mood and a
    /// document does not have one. Monospaced because it is a transcript, and
    /// because it makes a receipt's columns line up instead of collapsing into
    /// prose.
    private var quotation: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(FridayTheme.textSecondary.opacity(0.35))
                .frame(width: 2)

            Text(displayText)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(FridayTheme.textSecondary)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Text read from the page")
        .accessibilityValue(displayText)
    }
}

/// Three dots, breathing, while a turn has nothing to show yet.
///
/// The animation is fine here and would not be at rest: this only exists while
/// the engine is in `.thinking`, which is an active state the user is watching.
/// D-50's rule is that *idle* costs nothing — not that nothing may ever move.
private struct ThinkingDots: View {
    var tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifted = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint.opacity(0.75))
                    .frame(width: 7, height: 7)
                    .scaleEffect(lifted ? 1 : 0.55)
                    .animation(
                        reduceMotion
                            ? nil
                            // Staggered by 150ms so it reads as a wave rather
                            // than a flash, which is the difference between
                            // "thinking" and "loading".
                            : .easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                        value: lifted
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.34), lineWidth: 1)
        )
        .onAppear { lifted = true }
        .accessibilityLabel("FRIDAY is thinking")
    }
}
