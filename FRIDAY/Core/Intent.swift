import Foundation

/// What the boss asked for, decided in Swift rather than by the model.
///
/// The on-device model is ~3B parameters. On this device it routed "what time
/// is it" to the reminder tool, "what can you do" to the battery tool, and
/// staged a reminder titled "What time is it?". Three rounds of tightening tool
/// descriptions and persona rules did not fix it, because tool selection is
/// simply not something a model this size does reliably with several tools in
/// play.
///
/// So routing is no longer the model's job. Code decides which tool runs, and
/// the model is left with the one thing it is genuinely good at: phrasing a
/// conversational reply. A tool can no longer fire on a turn that was not
/// routed to it, which makes the whole class of mis-routing impossible rather
/// than merely less likely.
enum Intent: Equatable {
    case time(includeDate: Bool)
    case device(aspect: String)
    case calendar(day: String)
    case reminder(title: String, when: String)
    /// Nothing to look up — hand it to the model.
    case chat
}

enum Router {
    /// Order matters. Reminders are checked first because "remind me at six"
    /// also contains time words, and a mis-order there would answer the clock
    /// instead of staging the reminder.
    static func intent(for input: String) -> Intent {
        let text = input.lowercased()

        if contains(text, ["remind me", "reminder", "remember to", "don't let me forget"]) {
            return .reminder(title: reminderTitle(from: input), when: input)
        }

        if let aspect = deviceAspect(in: text) {
            return .device(aspect: aspect)
        }

        if contains(text, ["calendar", "schedule", "agenda", "my meetings", "next meeting", "what's on today", "whats on today", "what's on my day"]) {
            return .calendar(day: text.contains("tomorrow") ? "tomorrow" : "today")
        }

        // "what time" and "the time" are safe; a bare "time" is not — "do I have
        // time for coffee" must stay a conversation.
        if contains(text, ["what time", "the time", "what's the time", "whats the time",
                           "current time", "time is it", "clock"]) {
            return .time(includeDate: false)
        }

        if contains(text, ["what date", "what's the date", "whats the date",
                           "what day", "today's date"]) {
            return .time(includeDate: true)
        }

        return .chat
    }

    // MARK: - Pieces

    private static func contains(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// Needles are deliberately multi-word where a single word would over-match.
    /// "hot" alone sent "how hot is it outside" — a weather question — to the
    /// phone's thermal state, and "space" alone caught every mention of space.
    /// A missed route falls through to chat, which is a far better failure than
    /// confidently answering the wrong question.
    private static func deviceAspect(in text: String) -> String? {
        if contains(text, ["battery", "charging", "charged", "power left", "how much power"]) {
            return "battery"
        }
        if contains(text, ["storage", "disk space", "free space", "space left", "memory left", "how much space"]) {
            return "storage"
        }
        if contains(text, ["wifi", "wi-fi", "network", "am i online", "connection", "internet", "signal"]) {
            return "network"
        }
        if contains(text, ["temperature", "thermal", "overheat", "running hot", "how hot is the phone"]) {
            return "temperature"
        }
        return nil
    }

    /// Strips the request wrapper so the reminder reads as the task itself:
    /// "remind me to call mom at 6pm" becomes "call mom at 6pm".
    ///
    /// The trailing time is deliberately left in. `ReminderService.stage`
    /// passes the whole utterance to `CalendarTool.firstDate(in:)` for the due
    /// date, so parsing the time out here would be duplicated work — and a
    /// slightly long title is a far better failure than a lost due date.
    private static func reminderTitle(from input: String) -> String {
        var title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["remind me to ", "remind me that ", "remind me ", "set a reminder to ", "set a reminder "] {
            if title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
                break
            }
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs the tool a routed turn asked for and writes the sentence.
///
/// Shared by `FridayEngine` and `AskFridayIntent`. The intent cannot go through
/// the engine: the engine owns `AVAudioEngine` and the audio session, and an
/// App Intent answering Siri must never touch either.
///
/// The model never sees these strings. It echoed `TimeTool`'s output word for
/// word on device, and a 3B model paraphrasing a number can quietly change it —
/// the worst failure an assistant has. Composing here means the value is always
/// right and "boss" is always present.
@MainActor
enum Lookup {
    static func answer(for intent: Intent, reminders: ReminderService) async -> String {
        do {
            switch intent {
            case .time(let includeDate):
                return addressed(try await TimeTool().call(arguments: .init(includeDate: includeDate)))

            case .device(let aspect):
                return addressed(try await DeviceTool().call(arguments: .init(aspect: aspect)))

            case .calendar(let day):
                return addressed(try await CalendarTool().call(arguments: .init(day: day, nextOnly: false)))

            case .reminder(let title, let when):
                // Staging only — D-34. The write still needs the Add it button.
                reminders.stage(title: title, when: when)
                guard let pending = reminders.pending else {
                    return "I didn't catch what to remind you about, boss."
                }
                return "That's \(pending.title), \(pending.spokenWhen), boss. Say the word and I'll add it."

            case .chat:
                return ""
            }
        } catch {
            return "Couldn't get that one, boss. Say the word and I'll try again."
        }
    }

    /// Tools return plain factual sentences; FRIDAY always addresses him.
    static func addressed(_ sentence: String) -> String {
        let text = sentence.trimmingCharacters(in: .whitespaces)
        guard !text.lowercased().contains("boss") else { return text }
        return text.hasSuffix(".") ? String(text.dropLast()) + ", boss." : text + ", boss."
    }
}
