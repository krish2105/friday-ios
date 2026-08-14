import Observation
import UserNotifications

/// FRIDAY's own nudges.
///
/// Before this, a confirmed reminder was written to Apple Reminders with an
/// `EKAlarm` and the *Reminders app* did the nudging — in the system's voice,
/// with no trace of FRIDAY. She staged it, wrote it, and then went quiet
/// forever. This closes that loop: the reminder still lands in a real store
/// (D-34), but the thing that speaks up at the right moment is her.
///
/// **Local notifications only.** `UNUserNotificationCenter` scheduling needs no
/// push entitlement and no capability — that is remote notifications, which are
/// paid-gated. Nothing here touches provisioning, which is the constraint every
/// feature in this project is built against (D-32).
@MainActor
@Observable
final class FridayNotifier {

    /// Whether FRIDAY does the nudging, or Apple Reminders does.
    ///
    /// Both nudging is redundant and neither nudging loses the reminder, so this
    /// is a preference rather than a default. On, `ReminderService` saves the
    /// `EKReminder` *without* an alarm so Reminders stays quiet; off, it adds
    /// the alarm and this class schedules nothing.
    var nudgesHimself: Bool {
        didSet { defaults.set(nudgesHimself, forKey: Key.nudges) }
    }

    /// Whether FRIDAY sends an unprompted morning brief.
    ///
    /// **Off by default.** Everything else in this app answers a question; this
    /// is the only thing it does uninvited, and a daily notification nobody
    /// asked for is spam with a persona.
    var briefsInTheMorning: Bool {
        didSet { defaults.set(briefsInTheMorning, forKey: Key.brief) }
    }

    /// Whether iOS has been asked yet, and what it said.
    private(set) var isAuthorised: Bool?

    private let defaults = UserDefaults.standard

    private enum Key {
        static let nudges = "friday.nudgesHimself"
        static let brief = "friday.morningBrief"
    }

    enum Action {
        static let category = "friday.reminder"
        static let done = "friday.reminder.done"
        static let snooze = "friday.reminder.snooze"
        /// Ten minutes, in seconds.
        static let snoozeInterval: TimeInterval = 600
    }

    init() {
        nudgesHimself = defaults.object(forKey: Key.nudges) as? Bool ?? true
        briefsInTheMorning = defaults.object(forKey: Key.brief) as? Bool ?? false
    }

    // MARK: - Permission

    /// Asked on the first confirmed reminder rather than at launch.
    ///
    /// Same just-in-time shape as the microphone in `startListening`: the ask
    /// arrives at the moment it obviously makes sense, where a launch-time
    /// prompt is a stranger demanding things before saying hello.
    @discardableResult
    func requestAuthorisation() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        let granted = (try? await centre.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        isAuthorised = granted
        return granted
    }

    /// Registers the Done / Snooze actions. Called once at launch.
    ///
    /// Registering the category is free and does not prompt — only
    /// `requestAuthorization` does — so this can happen before the user has
    /// agreed to anything.
    func registerActions() {
        let done = UNNotificationAction(
            identifier: Action.done,
            title: "Done",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze,
            title: "Snooze 10 min",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Action.category,
            actions: [done, snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Scheduling

    /// Schedules a nudge, returning false if it could not be set.
    ///
    /// A date already past is refused rather than fired immediately — "remind me
    /// at six" said at seven should not buzz in his pocket the same second.
    @discardableResult
    func nudge(_ title: String, at date: Date) async -> Bool {
        guard nudgesHimself, date > Date() else { return false }
        guard await requestAuthorisation() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "FRIDAY"
        // Her register, not the system's. This is the whole point of the feature
        // — the line has to sound like her or Apple Reminders was doing it
        // better already.
        content.body = "You wanted a nudge, boss — \(title)"
        content.sound = .default
        content.categoryIdentifier = Action.category
        content.userInfo = ["title": title]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    /// Re-schedules a nudge ten minutes out. Used by the Snooze action.
    func snooze(_ title: String) async {
        let content = UNMutableNotificationContent()
        content.title = "FRIDAY"
        content.body = "Second time of asking, boss — \(title)"
        content.sound = .default
        content.categoryIdentifier = Action.category
        content.userInfo = ["title": title]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: Action.snoozeInterval,
                repeats: false
            )
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Handles a tap on Done or Snooze.
///
/// A separate non-isolated `NSObject` holding the work, which is HANDOVER §7's
/// pattern rather than a preference: `UNUserNotificationCenterDelegate` is
/// called by the system on its own terms, and every runtime crash this project
/// has had was a `@MainActor` type's closure inheriting isolation and then being
/// invoked elsewhere.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    private let notifier: FridayNotifier

    init(notifier: FridayNotifier) {
        self.notifier = notifier
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == FridayNotifier.Action.snooze,
              let title = response.notification.request.content.userInfo["title"] as? String
        else { return }

        await notifier.snooze(title)
    }

    /// Shows the nudge even with the app open. Without this iOS suppresses it,
    /// and a reminder you were promised silently not arriving is worse than one
    /// arriving at an awkward moment.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
