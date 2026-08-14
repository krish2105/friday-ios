import Foundation

/// What you can do with something FRIDAY just read.
///
/// Reading a poster and being told what it says is half an answer. The half that
/// matters is "and it's on the 20th at 7 — do you want that in your calendar?"
///
/// **The date comes from `NSDataDetector`, not from the model.** It is the same
/// detector `CalendarTool.firstDate(in:)` already uses, it understands "next
/// Friday" and "20 Aug 7pm" without being asked nicely, and — the point — it
/// cannot invent one. A model asked to find a date in a page will always find a
/// date. That is D-44's rule applied to the *absence* of a fact rather than the
/// value of one.
enum ScanFollowUp {

    /// The last thing read, kept only for the session.
    ///
    /// Ephemeral by decision, not by omission: conversations are not written to
    /// disk, and this is part of a conversation. It dies with the app, which is
    /// why "add that to my calendar" works a minute later and not tomorrow.
    struct Scanned: Equatable, Sendable {
        var text: String
        var date: Date?

        /// A short title from the first line worth calling a title.
        ///
        /// The first line is usually the heading on a poster or the shop on a
        /// receipt. Lines that are only punctuation or digits are skipped —
        /// a receipt beginning with a bill number would otherwise become a
        /// calendar event called "4471".
        var title: String {
            let candidate = text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { line in
                    line.count >= 3 && line.contains(where: \.isLetter)
                }
            return candidate.map { String($0.prefix(60)) } ?? "That thing you scanned"
        }
    }

    static func scanned(_ text: String) -> Scanned {
        Scanned(text: text, date: CalendarTool.firstDate(in: text))
    }

    /// Whether a turn is asking to act on the last scan.
    ///
    /// Needles carry a **back-reference** — "that", "this", "it" — because that
    /// is what makes a follow-up a follow-up. "Put lunch in my calendar" is a
    /// fresh request with its own subject and is already routed; "put that in my
    /// calendar" has no subject at all unless something was read first.
    static func isFollowUp(_ text: String) -> Bool {
        let lowered = text.lowercased()

        let backReference = ["that", "this", "it"]
        guard backReference.contains(where: lowered.contains) else { return false }

        return ["add that", "add this", "put that", "put this", "save that",
                "save this", "remind me about that", "remind me about this",
                "remind me of that", "calendar that", "diary that"]
            .contains(where: lowered.contains)
    }

    /// Whether the follow-up wants a reminder rather than a calendar entry.
    static func wantsReminder(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("remind") || lowered.contains("reminder")
    }
}
