import Foundation
import UIKit

/// Timers and the clipboard — two small things a daily driver is expected to do.
///
/// The timer is a **local notification**, not a countdown the app has to stay
/// alive to run. That is the only design that survives the app being
/// backgrounded, which is where a phone spends most of its life, and it costs
/// nothing extra: `FridayNotifier` already exists for reminders.
enum TimerTool {

    /// Seconds, parsed from what someone would say.
    ///
    /// Handles "10 minutes", "1 hour 30", "90 seconds", "an hour". Returns nil
    /// rather than guessing — a timer set for the wrong duration is worse than
    /// one that asks again.
    static func seconds(in text: String) -> Int? {
        let lowered = text.lowercased()
        var total = 0
        var found = false

        // Longest unit names first so "minutes" is never matched as "min" with
        // "utes" left over.
        let units: [(names: [String], multiplier: Int)] = [
            (["hours", "hour", "hrs", "hr"], 3600),
            (["minutes", "minute", "mins", "min"], 60),
            (["seconds", "second", "secs", "sec"], 1)
        ]

        for (names, multiplier) in units {
            for name in names {
                guard let range = lowered.range(of: name) else { continue }

                // The number immediately before the unit.
                let before = lowered[lowered.startIndex..<range.lowerBound]
                let digits = before.reversed()
                    .drop { $0 == " " }
                    .prefix { $0.isNumber }
                    .reversed()

                if let value = Int(String(digits)) {
                    total += value * multiplier
                    found = true
                } else if before.hasSuffix("an ") || before.hasSuffix("a ") {
                    // "an hour", "a minute"
                    total += multiplier
                    found = true
                }
                break
            }
        }

        guard found, total > 0 else { return nil }
        return total
    }

    /// How FRIDAY says a duration back — "10 minutes", "1 hour 30 minutes".
    static func spoken(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remaining = seconds % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if remaining > 0, hours == 0 { parts.append("\(remaining) second\(remaining == 1 ? "" : "s")") }

        return parts.isEmpty ? "no time at all" : parts.joined(separator: " ")
    }
}

/// What's on the clipboard.
///
/// `UIPasteboard.general.string` shows the system's paste banner on first read,
/// which is correct and should not be worked around — reading someone's
/// clipboard is exactly the thing an OS should announce.
@MainActor
enum ClipboardTool {
    static func answer() -> String {
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return "There's nothing on your clipboard, boss."
        }

        // Long enough to be a document is read as one — same threshold and same
        // reasoning as a scan, and bounded for D-61's reason.
        guard text.count <= 240 else {
            return "It's a long one, boss. Here's the start of it: \(text.prefix(240))…"
        }
        return "Your clipboard says: \(text)"
    }
}
