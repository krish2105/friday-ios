import SwiftUI

/// The empty state — which is the screen FRIDAY is looked at in most.
///
/// Before this it was a greeting in the top-left corner and roughly 55% of the
/// display doing nothing. Two things were wrong with that. The orb sat at the
/// bottom competing with a text field, so the one element that *is* FRIDAY read
/// as a secondary control; and sixteen capabilities were reachable only by a
/// phrase you already knew.
///
/// The suggestions fix the second properly. With keyword routing (D-43) a
/// capability exists exactly as far as someone knows how to ask for it — so a
/// chip that shows the phrase **and runs it** teaches the words for next time.
/// That is strictly better than the action row added in stage 8, which still
/// required knowing to press it.
///
/// Everything here is static. No gradient drifts, nothing pulses, and the orb is
/// frozen at rest exactly as D-50 left it — the panel fills space rather than
/// animating in it, so idle CPU is unaffected.
struct HeroPanel: View {
    var state: FridayState
    var level: Float
    /// Shared with the small talk button so the orb travels between the two
    /// layouts rather than one vanishing and another appearing.
    var namespace: Namespace.ID
    var onPress: () -> Void
    var onRelease: () -> Void
    var onSuggestion: (String) -> Void

    /// Five, chosen for breadth rather than cleverness: one per area of the
    /// app, each phrased the way someone would actually say it, and each safe to
    /// run without setup beyond a permission prompt.
    private static let suggestions = [
        "What's on today",
        "Read this",
        "How many steps have I done",
        "How's my battery",
        "Whose birthday is next"
    ]

    private var greeting: String {
        switch state {
        case .listening: "I'm listening, boss."
        case .thinking: "Working on it, boss."
        case .speaking: ""
        case .error: "Something needs your attention, boss."
        case .idle: "Standing by, boss."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            TalkButton(
                state: state,
                level: level,
                diameter: 168,
                namespace: namespace,
                onPress: onPress,
                onRelease: onRelease
            )

            Text(greeting)
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(FridayTheme.textPrimary)
                .padding(.top, 22)

            Text("Hold to talk, or just start typing")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(FridayTheme.textSecondary)
                .padding(.top, 6)

            suggestions
                .padding(.top, 26)

            Spacer(minLength: 12)
        }
    }

    /// A flowing wrap rather than a grid, so a longer phrase is never truncated
    /// into something you cannot say.
    private var suggestions: some View {
        FlowLayout(spacing: 8) {
            ForEach(Self.suggestions, id: \.self) { phrase in
                Button {
                    onSuggestion(phrase)
                } label: {
                    Text(phrase)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(FridayTheme.amberLight)
                        .padding(.horizontal, 14)
                        // 44pt tall, because a chip is a touch target and not a
                        // label that happens to be tappable.
                        .frame(minHeight: 44)
                        .background(Capsule().fill(FridayTheme.amber.opacity(0.09)))
                        .overlay(Capsule().strokeBorder(FridayTheme.amber.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(phrase)
                .accessibilityHint("Asks FRIDAY this")
            }
        }
    }
}

/// Wraps its children onto as many rows as they need.
///
/// SwiftUI has no flow layout of its own, and the alternatives are worse: a
/// `LazyVGrid` forces equal columns, which stretches "Read this" to the width of
/// "How many steps have I done" and makes the set look like a form. Phrases
/// should be as wide as the words in them.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = rows(for: subviews, in: width)

        let height = rows.reduce(into: CGFloat.zero) { total, row in
            total += row.height + (total > 0 ? spacing : 0)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY

        for row in rows(for: subviews, in: bounds.width) {
            // Centred, because a ragged left edge under a centred orb reads as
            // a mistake rather than a choice.
            var x = bounds.minX + (bounds.width - row.width) / 2

            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width

            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }

            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
