import Foundation

/// Shared helpers for FRIDAY's tools.
///
/// Two rules hold across every tool in this directory:
///
/// 1. **Never throw into the model's context.** Whatever a tool returns is read
///    by a 3B model and then spoken aloud. A raw `NSError` becomes FRIDAY
///    reading an error domain out loud. Failures come back through
///    `FridayTool.failed(_:)` instead.
/// 2. **Never leak vocabulary.** Return values must contain no tool names,
///    function names or type names — the persona contract forbids FRIDAY ever
///    saying them, and the surest way to prevent it is never to put them where
///    she can read them.
enum FridayTool {
    /// Phrase a failure for the model. Plain language, no technical detail.
    static func failed(_ reason: String) -> String {
        "That didn't work: \(reason). Tell boss calmly, in your own words, and offer to try again."
    }

    /// Phrase a permission denial, naming where to fix it.
    static func denied(_ what: String, settingsPath: String) -> String {
        "No access to \(what). Tell boss calmly that you can't see it, and that access can be turned on in \(settingsPath)."
    }
}
