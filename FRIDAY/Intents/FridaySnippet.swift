import AppIntents
import SwiftUI

/// FRIDAY's answer as a card, for Siri and Spotlight.
///
/// Session 7 returned a bare `IntentDialog`, so asking Siri got a spoken line
/// and a plain grey bubble that could have come from any app. iOS 26's
/// interactive snippets let an intent hand back a real view, so the answer looks
/// like FRIDAY wherever it surfaces.
///
/// It is a **separate** `SnippetIntent` rather than a view returned inline
/// because that is how iOS 26 models it: the system re-runs the snippet intent
/// to refresh the card, so the content has to be reproducible from its
/// parameters alone. Everything the card draws is therefore a parameter.
struct FridayAnswerSnippet: SnippetIntent {
    static let title: LocalizedStringResource = "FRIDAY's Answer"

    /// Not surfaced in Shortcuts — nobody adds "show a snippet" to a shortcut by
    /// hand; it exists to be presented by `AskFridayIntent`.
    static let isDiscoverable = false

    @Parameter(title: "Answer")
    var answer: String

    init() {}

    init(answer: String) {
        self.answer = answer
    }

    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: FridayAnswerCard(answer: answer))
    }
}

/// The card itself, in FRIDAY's palette rather than the system's.
///
/// Deliberately plain: no animation, no glass. A snippet is rendered by another
/// process in a context we do not control the size of, and the ambient field and
/// `.glassEffect` both assume a full screen behind them.
private struct FridayAnswerCard: View {
    var answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(FridayTheme.amber)
                    .frame(width: 5, height: 5)

                Text("F.R.I.D.A.Y.")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(FridayTheme.amber)
            }

            Text(answer)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(FridayTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                // Bounded, for D-61's reason. A snippet is laid out by another
                // process and an unbounded answer is not this app's to render.
                .lineLimit(8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FridayTheme.ground)
        )
    }
}
