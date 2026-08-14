import CoreMotion
import Foundation

/// Steps, distance and flights climbed — without HealthKit.
///
/// This is the free route to a paid-gated feature, and worth understanding as
/// such. HealthKit needs a capability the Personal Team cannot sign (D-32), the
/// same wall that killed WeatherKit and the widget's App Group. `CoreMotion`
/// needs only `NSMotionUsageDescription`, reads the motion coprocessor directly,
/// and answers the question people actually ask: how far have I walked today.
///
/// Numbers are formatted here in Swift and never paraphrased by the model — the
/// same rule as every other factual answer (D-44).
enum MotionTool {

    /// What can be asked about movement.
    enum Aspect: Equatable, Sendable {
        case steps
        case distance
        case flights
    }

    /// `CMPedometer` keeps **seven days** of history and no more. Asking for
    /// last month is declined honestly rather than answered with a silent zero,
    /// which would be a wrong number presented as a fact.
    static let historyDays = 7

    /// The three numbers, lifted out of `CMPedometerData` while still on the
    /// callback's queue.
    ///
    /// `CMPedometerData` is not `Sendable` and the handler is invoked on a queue
    /// of CoreMotion's choosing, so the object itself must not cross back — only
    /// these values do. Same discipline as HANDOVER §7's delegate rule: take
    /// what you need where the callback lands, and carry nothing else out.
    private struct Reading: Sendable {
        var steps: Int
        var metres: Double?
        var flights: Int?
    }

    /// `queryPedometerData` is completion-handler only — there is no async
    /// overload in the iOS 26 SDK, checked rather than assumed after the
    /// compiler rejected `from:to:`.
    private static func reading(from start: Date, to end: Date) async -> Reading? {
        await withCheckedContinuation { continuation in
            // Built here, per call. A `static let` pedometer does not compile
            // under strict concurrency — "non-Sendable type may have shared
            // mutable state" — and a local one the compiler can prove is
            // uniquely owned removes the hazard rather than silencing it.
            let pedometer = CMPedometer()
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Reading(
                    steps: data.numberOfSteps.intValue,
                    metres: data.distance?.doubleValue,
                    flights: data.floorsAscended?.intValue
                ))
            }
        }
    }

    static func answer(aspect: Aspect, dayOffset: Int = 0) async -> String {
        guard CMPedometer.isStepCountingAvailable() else {
            return "This phone can't count steps, boss."
        }
        guard dayOffset <= 0, -dayOffset <= historyDays else {
            return "I only keep the last week of steps, boss — anything older is gone."
        }

        let calendar = Calendar.current
        let now = Date()
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
            return "I couldn't work that day out, boss."
        }
        let start = calendar.startOfDay(for: day)
        let end = dayOffset == 0
            ? now
            : min(calendar.date(byAdding: .day, value: 1, to: start) ?? now, now)

        guard let data = await reading(from: start, to: end) else {
            // Not the same as zero. A phone left on a desk has no data; a phone
            // carried all day and not walked with has zero. Saying "zero, boss"
            // for the first is a wrong answer, so they are kept distinct.
            return "I've got no movement recorded for \(label(dayOffset)), boss."
        }

        let when = label(dayOffset)

        switch aspect {
        case .steps:
            return "You've done \(data.steps.formatted()) steps \(when), boss."

        case .distance:
            guard let metres = data.metres else {
                return "There's no distance recorded \(when), boss."
            }
            // The style is named explicitly. `.measurement(width:usage:)` cannot
            // infer its unit from the call site and fails to compile.
            let formatted = Measurement(value: metres, unit: UnitLength.meters)
                .formatted(Measurement<UnitLength>.FormatStyle(width: .abbreviated, usage: .road))
            return "You've covered \(formatted) \(when), boss."

        case .flights:
            guard let climbed = data.flights else {
                return "This phone doesn't track stairs, boss."
            }
            return climbed == 1
                ? "One flight of stairs \(when), boss."
                : "\(climbed) flights of stairs \(when), boss."
        }
    }

    private static func label(_ dayOffset: Int) -> String {
        switch dayOffset {
        case 0: "today"
        case -1: "yesterday"
        default: "\(-dayOffset) days ago"
        }
    }
}
