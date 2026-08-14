import EventKit
import Foundation
import Observation

/// Stages and commits calendar events.
///
/// A deliberate mirror of `ReminderService`, down to the method names. The
/// confirmation card, the Hindi path and D-34's staged-write rule all work
/// identically as a result, and nobody reading this has to learn a second shape
/// for the same idea.
///
/// `CalendarTool` reads; this writes. The split is the point: reading is
/// answered inline, writing waits for a real press.
@MainActor
@Observable
final class EventService {
    struct Pending: Identifiable, Equatable, Sendable {
        let id = UUID()
        var title: String
        var startDate: Date

        /// One hour unless told otherwise. Guessing a duration from "lunch with
        /// Priya" is a fiction; an hour is the honest default and is trivially
        /// edited in Calendar afterwards.
        var endDate: Date { startDate.addingTimeInterval(3600) }

        var spokenWhen: String {
            "for \(startDate.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private(set) var pending: Pending?

    /// Returns false when no time could be found, which is a question rather
    /// than a failure — an event with a guessed time is worse than none.
    @discardableResult
    func stage(title: String, when: String) -> Bool {
        guard let start = CalendarTool.firstDate(in: when) else { return false }
        pending = Pending(title: title, startDate: start)
        return true
    }

    func cancel() {
        pending = nil
    }

    /// Actually create the event. Returns what FRIDAY should say.
    func confirm() async -> String {
        guard let pending else { return "" }
        self.pending = nil

        let store = EKEventStore()
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else {
                return "I can't add to your calendar without access, boss. You can switch it on in Settings, under FRIDAY."
            }
        } catch {
            return "I can't add to your calendar without access, boss. You can switch it on in Settings, under FRIDAY."
        }

        guard let calendar = store.defaultCalendarForNewEvents else {
            return "There's no calendar to add to, boss."
        }

        let event = EKEvent(eventStore: store)
        event.title = pending.title
        event.startDate = pending.startDate
        event.endDate = pending.endDate
        event.calendar = calendar

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return "Done, boss. \(pending.title) is in your calendar \(pending.spokenWhen)."
        } catch {
            return "Couldn't put that in the calendar, boss. Want me to try again?"
        }
    }
}
