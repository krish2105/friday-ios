import EventKit
import FoundationModels

/// Read-only access to the calendar.
struct CalendarTool: Tool {
    let name = "calendarEvents"
    let description = "The user's calendar events for a given day."

    @Generable
    struct Arguments {
        @Guide(description: "Which day: today, tomorrow, or a date like 2026-08-20")
        let day: String

        @Guide(description: "True to return only the very next event")
        let nextOnly: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        let store = EKEventStore()

        do {
            // iOS 17+ access API. Read-only work still needs full access to see
            // event details rather than just busy blocks.
            guard try await store.requestFullAccessToEvents() else {
                return FridayTool.denied("the calendar", settingsPath: "Settings, under FRIDAY")
            }
        } catch {
            return FridayTool.denied("the calendar", settingsPath: "Settings, under FRIDAY")
        }

        let calendar = Calendar.current
        let day = Self.resolveDay(arguments.day, calendar: calendar)
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return FridayTool.failed("that day couldn't be worked out")
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var events = store.events(matching: predicate)
            .filter { !$0.isAllDay || calendar.isDate($0.startDate, inSameDayAs: start) }
            .sorted { $0.startDate < $1.startDate }

        if arguments.nextOnly {
            let now = Date()
            events = events.filter { $0.endDate > now }
            if let next = events.first { events = [next] } else { events = [] }
        }

        // Subscribed calendars overlap, and EventKit reports each copy as a
        // separate event because to it they *are* separate. A public holiday
        // carried by four subscribed calendars produced "Independence Day, all
        // day; Independence Day, all day; Independence Day, all day;
        // Independence Day, all day" on device — technically correct and
        // useless.
        //
        // Deduplicated on what a person would call the same event: the same
        // title, starting at the same moment.
        var seen: Set<String> = []
        events = events.filter { event in
            let key = "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)"
            return seen.insert(key).inserted
        }

        guard !events.isEmpty else {
            return "Nothing on the calendar for \(Self.label(for: day, calendar: calendar))."
        }

        let lines = events.prefix(6).map { event -> String in
            let title = event.title ?? "an untitled event"
            if event.isAllDay { return "\(title), all day" }
            return "\(title) at \(event.startDate.formatted(date: .omitted, time: .shortened))"
        }

        return "For \(Self.label(for: day, calendar: calendar)): " + lines.joined(separator: "; ") + "."
    }

    // MARK: - Day parsing

    private static func resolveDay(_ raw: String, calendar: Calendar) -> Date {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let today = Date()

        if text.isEmpty || text.contains("today") { return today }
        if text.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today
        }
        if text.contains("yesterday") {
            return calendar.date(byAdding: .day, value: -1, to: today) ?? today
        }

        // Anything else: let the system find a date in the phrase rather than
        // trusting a 3B model to emit a strict format.
        if let detected = Self.firstDate(in: raw) { return detected }
        return today
    }

    static func firstDate(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.date
    }

    private static func label(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "today" }
        if calendar.isDateInTomorrow(day) { return "tomorrow" }
        if calendar.isDateInYesterday(day) { return "yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}
