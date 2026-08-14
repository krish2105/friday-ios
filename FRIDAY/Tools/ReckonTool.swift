import Foundation

/// Arithmetic, percentages and unit conversion — worked out in Swift.
///
/// This is D-44 at its cleanest. A ~3B model asked "what's 15% of 4,200" will
/// answer confidently and is under no obligation to be right; `NSExpression`
/// either evaluates or it does not. Every number FRIDAY says here was computed,
/// not recalled, and the model never sees the question.
enum ReckonTool {

    /// What was asked. Parsed in `Router`, computed here.
    enum Sum: Equatable, Sendable {
        /// "15% of 4200"
        case percentage(Double, of: Double)
        /// "12 miles in km"
        case convert(Double, from: String, to: String)
        /// Anything `NSExpression` will take: "4200 * 0.15", "(3+4)/2"
        case arithmetic(String)
    }

    static func answer(_ sum: Sum) -> String {
        switch sum {
        case .percentage(let percent, let total):
            let result = total * percent / 100
            return "\(format(percent))% of \(format(total)) is \(format(result)), boss."

        case .convert(let value, let from, let to):
            guard let converted = convert(value, from: from, to: to) else {
                return "I can't turn \(from) into \(to), boss."
            }
            return "\(format(value)) \(from) is \(format(converted)) \(to), boss."

        case .arithmetic(let expression):
            guard let result = evaluate(expression) else {
                return "I couldn't work that one out, boss."
            }
            return "That's \(format(result)), boss."
        }
    }

    // MARK: - Arithmetic

    /// `NSExpression` rather than a hand-rolled parser.
    ///
    /// It handles precedence and parentheses correctly, which a weekend parser
    /// does not, and it is decades old. It **throws Objective-C exceptions** on
    /// malformed input rather than returning nil, which Swift cannot catch — so
    /// the input is validated to digits and operators *before* it is handed
    /// over. That check is the safety, not a nicety.
    static func evaluate(_ raw: String) -> Double? {
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() ")
        let cleaned = raw.replacingOccurrences(of: ",", with: "")

        guard !cleaned.isEmpty,
              cleaned.unicodeScalars.allSatisfy(allowed.contains),
              cleaned.rangeOfCharacter(from: .decimalDigits) != nil,
              // A trailing operator is exactly the shape that throws.
              let last = cleaned.trimmingCharacters(in: .whitespaces).last,
              last.isNumber || last == ")"
        else { return nil }

        let value = NSExpression(format: cleaned).expressionValue(with: nil, context: nil)
        return (value as? NSNumber)?.doubleValue
    }

    // MARK: - Units

    /// The conversions people actually ask for out loud.
    ///
    /// Deliberately not every unit `Foundation` knows. A table you can read is
    /// worth more here than exhaustive coverage nobody will use, and each entry
    /// is a name someone would actually say rather than a symbol.
    private static let units: [String: Dimension] = [
        "km": UnitLength.kilometers, "kilometres": UnitLength.kilometers,
        "kilometers": UnitLength.kilometers, "kilometre": UnitLength.kilometers,
        "miles": UnitLength.miles, "mile": UnitLength.miles,
        "metres": UnitLength.meters, "meters": UnitLength.meters, "m": UnitLength.meters,
        "feet": UnitLength.feet, "foot": UnitLength.feet, "ft": UnitLength.feet,
        "inches": UnitLength.inches, "inch": UnitLength.inches,
        "cm": UnitLength.centimeters, "centimetres": UnitLength.centimeters,

        "kg": UnitMass.kilograms, "kilos": UnitMass.kilograms, "kilograms": UnitMass.kilograms,
        "pounds": UnitMass.pounds, "lbs": UnitMass.pounds, "lb": UnitMass.pounds,
        "grams": UnitMass.grams, "g": UnitMass.grams,
        "ounces": UnitMass.ounces, "oz": UnitMass.ounces,

        "celsius": UnitTemperature.celsius, "c": UnitTemperature.celsius,
        "fahrenheit": UnitTemperature.fahrenheit, "f": UnitTemperature.fahrenheit,

        "litres": UnitVolume.liters, "liters": UnitVolume.liters, "l": UnitVolume.liters,
        "gallons": UnitVolume.gallons, "gallon": UnitVolume.gallons,
        "ml": UnitVolume.milliliters,

        "hours": UnitDuration.hours, "hour": UnitDuration.hours,
        "minutes": UnitDuration.minutes, "minute": UnitDuration.minutes,
        "seconds": UnitDuration.seconds
    ]

    static func unit(named name: String) -> Dimension? {
        units[name.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    static func convert(_ value: Double, from: String, to: String) -> Double? {
        guard let source = unit(named: from), let target = unit(named: to) else { return nil }
        // Kilograms into kilometres is not a conversion, it is a category
        // error, and `Measurement` would happily produce a number for it.
        guard type(of: source) == type(of: target) else { return nil }
        return Measurement(value: value, unit: source).converted(to: target).value
    }

    // MARK: - Saying a number

    /// Trailing zeros dropped, thousands grouped.
    ///
    /// "630" rather than "630.0", because the second is a computer talking.
    static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return Int(rounded).formatted()
        }
        return rounded.formatted(.number.precision(.fractionLength(0...2)))
    }
}
