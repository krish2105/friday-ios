import ActivityKit
import SwiftUI
import WidgetKit

/// The running timer, in the Island and on the Lock Screen.
///
/// Every countdown here is `Text(timerInterval:countsDown:)`, which the **system**
/// ticks rather than the app. That is the whole reason this is cheap: the
/// activity is requested once and never updated, where a per-second push would
/// exhaust ActivityKit's budget in under a minute and then silently stop —
/// leaving a frozen clock, which is worse than no clock.
struct FridayTimerActivity: Widget {
    private let amber = Color(red: 1.000, green: 0.702, blue: 0.231)
    private let primary = Color(white: 0.965)
    private let secondary = Color(white: 0.640)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color(red: 0.043, green: 0.047, blue: 0.055))
                .activitySystemActionForegroundColor(amber)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("FRIDAY", systemImage: "timer")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(amber)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(to: context.state.deadline, size: 20)
                        .foregroundStyle(primary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.label)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(secondary)
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(amber)
            } compactTrailing: {
                countdown(to: context.state.deadline, size: 13)
                    .foregroundStyle(amber)
                    // The compact slot is narrow; without a width the countdown
                    // is clipped the moment it needs a tens digit.
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(amber)
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<TimerAttributes>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(amber)

            VStack(alignment: .leading, spacing: 2) {
                Text("FRIDAY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(amber)
                Text(context.attributes.label)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(secondary)
            }

            Spacer(minLength: 8)

            countdown(to: context.state.deadline, size: 28)
                .foregroundStyle(primary)
        }
        .padding(16)
    }

    /// Monospaced digits so the layout does not jump every second as the glyph
    /// widths change — the difference between a timer and a twitch.
    private func countdown(to deadline: Date, size: CGFloat) -> some View {
        Text(timerInterval: Date()...deadline, countsDown: true)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}
