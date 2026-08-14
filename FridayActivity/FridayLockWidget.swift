import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen widget. Tap it and FRIDAY opens listening.
///
/// Master Build §13 asks for "a Lock Screen widget showing last brief
/// timestamp". It deliberately shows no timestamp.
///
/// A widget runs in its own process, so reading anything the app wrote needs an
/// App Group — a capability that requires a paid membership to register and
/// which, added on a free account, risks breaking provisioning outright, the
/// same trap as WeatherKit in D-32. Unlike the Control Centre control there is
/// no `openAppWhenRun` escape hatch, because the widget has to render its
/// content *before* anyone taps it.
///
/// So this is a launcher rather than a display. Owner's decision, taken with
/// the trade-off stated. If the account is ever upgraded, add the App Group,
/// write the timestamp from `FridayEngine` and read it in `timeline(...)`.
struct FridayLockEntry: TimelineEntry {
    let date: Date
}

struct FridayLockProvider: TimelineProvider {
    func placeholder(in context: Context) -> FridayLockEntry {
        FridayLockEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (FridayLockEntry) -> Void) {
        completion(FridayLockEntry(date: Date()))
    }

    /// `.never` because nothing here changes. Asking WidgetKit to refresh a
    /// static launcher would spend the app's refresh budget for no reason.
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<FridayLockEntry>) -> Void) {
        completion(Timeline(entries: [FridayLockEntry(date: Date())], policy: .never))
    }
}

struct FridayLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.krishnamathur.friday.lockscreen",
            provider: FridayLockProvider()
        ) { _ in
            FridayLockView()
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Talk to FRIDAY")
        .description("Opens FRIDAY ready to listen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

private struct FridayLockView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        // Reuses the same intent as the Control Centre control, so both entry
        // points land in exactly the same place.
        Button(intent: StartListeningIntent()) {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 7) {
                    orb
                    Text("Talk to FRIDAY")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                }
            default:
                orb
            }
        }
        .buttonStyle(.plain)
    }

    private var orb: some View {
        Image(systemName: "waveform.circle.fill")
            .font(.system(size: family == .accessoryRectangular ? 16 : 22))
    }
}
