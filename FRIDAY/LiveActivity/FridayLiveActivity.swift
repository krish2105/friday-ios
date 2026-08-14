import ActivityKit
import SwiftUI
import WidgetKit

/// ⚠️ TARGET MEMBERSHIP — this file belongs to the **widget extension target
/// only**, never the app target. It is intentionally not in the app's Sources
/// build phase.
///
/// After creating the extension (File → New → Target → Widget Extension, tick
/// "Include Live Activity"), add this file to it and reference
/// `FridayLiveActivity()` from the generated `WidgetBundle`.
struct FridayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FridayAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(orbAmber)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    orb(size: 26)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(orbAmber)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.snippet.isEmpty {
                        Text(context.state.snippet)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                orb(size: 16)
            } compactTrailing: {
                Text(context.state.status)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(orbAmber)
            } minimal: {
                orb(size: 16)
            }
            .keylineTint(orbAmber)
        }
    }

    // MARK: - Pieces

    private var orbAmber: Color { Color(red: 1.0, green: 0.702, blue: 0.231) }

    private func orb(size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [orbAmber, orbAmber.opacity(0.15)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .overlay(Circle().strokeBorder(orbAmber.opacity(0.6), lineWidth: 1))
            .frame(width: size, height: size)
    }

    private func lockScreen(_ state: FridayAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            orb(size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.status)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(orbAmber)

                if !state.snippet.isEmpty {
                    Text(state.snippet)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
