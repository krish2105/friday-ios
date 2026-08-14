import CoreMotion
import EventKit
import SwiftUI
import WidgetKit

/// A Home Screen widget that shows something, which the Lock Screen one could
/// not.
///
/// D-52 made the Lock Screen widget a launcher because a widget runs in its own
/// process and reading what the *app* wrote needs an App Group — paid-gated, and
/// adding it on a free account risks provisioning outright (D-32). That reasoning
/// still stands, and this sidesteps it rather than contradicting it: **the widget
/// does not read the app's data. It reads the same sources the app does.**
/// EventKit and CoreMotion are system stores, available to any process the user
/// has granted, so no shared container is involved at all.
///
/// **It never requests access — only checks it.** That matters twice over. A
/// widget has no business raising a permission prompt from the Home Screen,
/// where there is no context for the question; and asking would need the usage
/// strings duplicated into this extension's own Info.plist, which is exactly the
/// kind of second copy that drifts. Where access has not been granted the widget
/// says so and points at the app, which is where the question belongs.
struct FridayStatusEntry: TimelineEntry {
    let date: Date
    /// Nil when the calendar has not been granted, or nothing is left today.
    var event: (title: String, start: Date)?
    /// Nil when motion has not been granted or has no data.
    var steps: Int?
    var hasCalendarAccess: Bool
}

struct FridayStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> FridayStatusEntry {
        FridayStatusEntry(
            date: Date(),
            event: ("Standup", Date().addingTimeInterval(3600)),
            steps: 4_820,
            hasCalendarAccess: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (FridayStatusEntry) -> Void) {
        Task { completion(await entry()) }
    }

    /// Refreshed on the half hour, or when the next event starts — whichever is
    /// sooner.
    ///
    /// WidgetKit budgets refreshes, so asking for more is asking for fewer later.
    /// Reloading exactly when the thing on screen stops being true is the most
    /// useful place to spend one.
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<FridayStatusEntry>) -> Void) {
        Task {
            let entry = await entry()
            let halfHour = Date().addingTimeInterval(1_800)
            let next = entry.event.map { min($0.start, halfHour) } ?? halfHour
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func entry() async -> FridayStatusEntry {
        let granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        return FridayStatusEntry(
            date: Date(),
            event: granted ? nextEvent() : nil,
            steps: await stepsToday(),
            hasCalendarAccess: granted
        )
    }

    /// The next event still to come today.
    private func nextEvent() -> (title: String, start: Date)? {
        let store = EKEventStore()
        let now = Date()
        guard let endOfDay = Calendar.current.date(
            bySettingHour: 23, minute: 59, second: 59, of: now
        ) else { return nil }

        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)

        // All-day events are excluded rather than shown: "Independence Day" is
        // not the next thing you have to be somewhere for, and it is what filled
        // the app's own calendar answer with noise before D-66 deduplicated it.
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
            .map { ($0.title ?? "Something", $0.startDate) }
    }

    /// Steps so far today, or nil.
    ///
    /// Checked rather than requested, same as the calendar — and `nil` covers
    /// both "not granted" and "no data", because on a Home Screen there is
    /// nothing useful to say about the difference.
    private func stepsToday() async -> Int? {
        guard CMPedometer.isStepCountingAvailable(),
              CMPedometer.authorizationStatus() == .authorized
        else { return nil }

        let start = Calendar.current.startOfDay(for: Date())

        return await withCheckedContinuation { continuation in
            // `CMPedometerData` is not Sendable and the handler lands on a queue
            // of CoreMotion's choosing, so only the number crosses back — the
            // same discipline `MotionTool` uses in the app.
            CMPedometer().queryPedometerData(from: start, to: Date()) { data, _ in
                continuation.resume(returning: data?.numberOfSteps.intValue)
            }
        }
    }
}

struct FridayStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.krishnamathur.friday.status",
            provider: FridayStatusProvider()
        ) { entry in
            FridayStatusView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.043, green: 0.047, blue: 0.055)
                }
        }
        .configurationDisplayName("Your Day")
        .description("The next thing on your calendar, and how far you've walked.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct FridayStatusView: View {
    var entry: FridayStatusEntry

    // The palette is repeated rather than shared. `FridayTheme` belongs to the
    // app target, and adding it to the extension would drag `AIStatus` and the
    // rest of the app's types across a boundary for four colours.
    private let amber = Color(red: 1.000, green: 0.702, blue: 0.231)
    private let primary = Color(white: 0.965)
    private let secondary = Color(white: 0.640)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(amber).frame(width: 4, height: 4)
                Text("F.R.I.D.A.Y.")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(amber)
            }

            Spacer(minLength: 8)

            if let event = entry.event {
                Text(event.start, style: .time)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(primary)

                Text(event.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(secondary)
                    .lineLimit(2)
            } else if !entry.hasCalendarAccess {
                Text("Open FRIDAY to let me see your calendar")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(secondary)
                    .lineLimit(3)
            } else {
                Text("Nothing left today")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(primary)
            }

            Spacer(minLength: 8)

            if let steps = entry.steps {
                Label {
                    Text("\(steps.formatted()) steps")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // The whole widget opens the app; a status readout has one obvious
        // destination and does not need a target inside it.
        .widgetURL(URL(string: "friday://open"))
        .accessibilityElement(children: .combine)
    }
}
