import EventKit
import Foundation
import UserNotifications

/// A short brief, waiting for you when you wake up.
///
/// Everything else in FRIDAY answers a question. This is the only thing she does
/// **unprompted**, which is why it is off by default: a daily notification
/// nobody asked for is not an assistant, it is spam with a persona.
///
/// **No background execution is involved, and none is needed.** The trick is
/// that tomorrow's calendar is already knowable today — so the brief is composed
/// and scheduled while the app is open, and iOS delivers it. That avoids
/// `BGAppRefreshTask` entirely, which would have meant a background mode in the
/// Info.plist for a feature that does not need one.
///
/// The cost of that is honest and worth stating: **the brief is only as fresh as
/// the last time the app was opened.** An event added on another device after
/// the brief was scheduled will not appear in it.
@MainActor
enum MorningBrief {
    static let identifier = "friday.morningBrief"

    /// 7:30, which is early enough to be useful and late enough not to be the
    /// thing that wakes you.
    static let hour = 7
    static let minute = 30

    /// Re-composes and re-schedules. Safe to call on every foreground.
    static func schedule(notifier: FridayNotifier) async {
        let centre = UNUserNotificationCenter.current()
        centre.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard notifier.briefsInTheMorning else { return }
        guard await notifier.requestAuthorisation() else { return }

        guard let next = nextBriefTime() else { return }
        let body = await summary(for: next)

        let content = UNMutableNotificationContent()
        content.title = "Morning, boss"
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: next
                ),
                // Not repeating. A repeat would fire the same sentence every
                // morning forever — a brief that is wrong by the second day is
                // worse than no brief. Re-scheduled on each foreground instead.
                repeats: false
            )
        )
        try? await centre.add(request)
    }

    /// The next 07:30 that has not already passed.
    private static func nextBriefTime() -> Date? {
        let calendar = Calendar.current
        let now = Date()

        guard let today = calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: now
        ) else { return nil }

        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// What the morning actually holds, composed in Swift.
    ///
    /// D-44 applies here as much as anywhere: this states a count and a time, and
    /// a notification cannot be corrected once it has been read.
    private static func summary(for day: Date) async -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return "Nothing I can see yet — open FRIDAY and let me at your calendar."
        }

        let store = EKEventStore()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return "Standing by."
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)

        // Timed events only, deduplicated — the same two corrections D-66 and
        // D-69 needed, for the same reason: overlapping subscribed calendars,
        // and holidays that are not appointments.
        var seen: Set<String> = []
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { seen.insert("\($0.title ?? "")|\($0.startDate.timeIntervalSince1970)").inserted }
            .sorted { $0.startDate < $1.startDate }

        guard let first = events.first else {
            return "Nothing in the diary today. Enjoy it."
        }

        let time = first.startDate.formatted(date: .omitted, time: .shortened)
        let title = first.title ?? "something"

        return events.count == 1
            ? "One thing today — \(title) at \(time)."
            : "\(events.count) things today. First is \(title) at \(time)."
    }
}
