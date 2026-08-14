import EventKit
import FoundationModels
import Observation

/// Stages and commits reminders.
///
/// The write is deliberately split in two. The model can only ever *stage* a
/// reminder; committing it takes a real button press from the user. A 3B model
/// cannot be trusted to sequence "ask first, then write" reliably, and the cost
/// of getting it wrong is junk appearing in someone's actual Reminders app.
@MainActor
@Observable
final class ReminderService {
    struct Pending: Identifiable, Equatable, Sendable {
        let id = UUID()
        var title: String
        var dueDate: Date?

        /// How FRIDAY should describe the timing aloud.
        var spokenWhen: String {
            guard let dueDate else { return "with no time set" }
            return "for \(dueDate.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private(set) var pending: Pending?

    func stage(title: String, when: String) {
        pending = Pending(title: title, dueDate: CalendarTool.firstDate(in: when))
    }

    func cancel() {
        pending = nil
    }

    /// Actually create the reminder. Returns what FRIDAY should say.
    func confirm() async -> String {
        guard let pending else { return "" }
        self.pending = nil

        let store = EKEventStore()
        do {
            guard try await store.requestFullAccessToReminders() else {
                return "I can't add reminders without access, boss. You can switch it on in Settings, under FRIDAY."
            }
        } catch {
            return "I can't add reminders without access, boss. You can switch it on in Settings, under FRIDAY."
        }

        guard let list = store.defaultCalendarForNewReminders() else {
            return "There's no reminders list to add to, boss."
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = pending.title
        reminder.calendar = list

        if let dueDate = pending.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }

        do {
            try store.save(reminder, commit: true)
            return pending.dueDate == nil
                ? "Done, boss. \(pending.title) is on your list."
                : "Done, boss. I'll remind you to \(pending.title.lowercased()) \(pending.spokenWhen)."
        } catch {
            return "Couldn't save that one, boss. Want me to try again?"
        }
    }
}

/// Prepares a reminder for the user to confirm. Never writes anything itself.
struct ReminderTool: Tool {
    let service: ReminderService

    let name = "prepareReminder"

    // Deliberately restrictive. The old wording — "Prepare a reminder for the
    // user to approve. Does not create it." — said what the tool does but never
    // when NOT to use it, and on device the model staged a reminder titled
    // "What time is it?" in response to someone asking the time. Tool
    // descriptions drive selection far more strongly than persona rules do, so
    // the guard belongs here.
    let description = """
    Stage a reminder for the user to approve. Use ONLY when he explicitly asks \
    to be reminded of something, such as "remind me to call mom at six". \
    Never use it to answer a question. Creates nothing on its own.
    """

    @Generable
    struct Arguments {
        @Guide(description: "What to be reminded about, in a few words")
        let title: String

        @Guide(description: "When, as the user said it, or empty if they didn't say")
        let when: String
    }

    func call(arguments: Arguments) async throws -> String {
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return "Ask boss what the reminder should say."
        }

        await service.stage(title: title, when: arguments.when)

        // The model must not claim success — nothing has been written yet.
        return "Ready but not saved. Read the reminder and its time back to boss and ask him to confirm. Do not say it has been created."
    }
}
