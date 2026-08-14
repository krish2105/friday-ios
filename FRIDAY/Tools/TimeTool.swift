import FoundationModels

/// Current date and time, in the user's own locale and timezone.
struct TimeTool: Tool {
    let name = "currentTime"
    let description = "The current time and date on this device."

    @Generable
    struct Arguments {
        @Guide(description: "True to include the date, false for the time alone")
        let includeDate: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        // `.formatted` picks up the device locale, calendar and timezone, so a
        // user in Mumbai and one in Cupertino both get something natural.
        let now = Date()
        let formatted = now.formatted(
            date: arguments.includeDate ? .complete : .omitted,
            time: .shortened
        )
        return "It is \(formatted)."
    }
}
