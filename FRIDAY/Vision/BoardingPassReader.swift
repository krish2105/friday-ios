import Foundation

/// The boarding-pass counterpart to `ReceiptReader`, built to the same rule:
/// **FRIDAY never states a fact she cannot point at.**
///
/// The shape is deliberately identical — a cheap Swift gate, then the model
/// selecting, then Swift refusing anything it cannot find on the page — because
/// that shape is the thing worth generalising from stage 3, not the receipt
/// specifics. A third document type should be another forty lines of the same.
///
/// One difference from receipts, and it is a real one: a boarding pass has no
/// single field that carries all the risk the way a total does. Getting the
/// gate wrong sends someone to the wrong end of a terminal; getting the flight
/// wrong is worse. So **every** field is verified, and any that fails is simply
/// not said.
enum BoardingPassReader {

    // MARK: - Is this a boarding pass

    /// Both halves required, exactly as `looksLikeReceipt`. Boarding words alone
    /// match a travel article; a flight-shaped code alone matches a car
    /// registration or a product SKU.
    static func looksLikeBoardingPass(_ text: String) -> Bool {
        let lowered = text.lowercased()

        // Strong signals only. "Terminal" and "class" were here and had to go —
        // a card receipt prints "Terminal ID", and "class" appears on half of
        // everything. Two of these together is a boarding pass; two weak ones is
        // a coincidence.
        let travel = ["boarding", "gate", "seat", "flight", "departure",
                      "passenger", "pnr", "booking ref"]
        let hits = travel.filter(lowered.contains).count

        // Two travel words, not one. "Gate" alone appears on a car park ticket.
        guard hits >= 2 else { return false }
        return containsFlightNumber(text)
    }

    /// Two or three letters or digits, then two to four digits — `6E 5231`,
    /// `BA117`, `AI 0102`. Airline codes are IATA two-character, so this is
    /// narrow by design.
    private static func containsFlightNumber(_ text: String) -> Bool {
        let tokens = text
            .split(whereSeparator: { $0 == " " || $0.isNewline })
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }

        for (index, token) in tokens.enumerated() {
            // Written closed up: "BA117".
            if isFlightNumber(token) { return true }

            // Split across a space — "6E 5231" — which is how most passes
            // actually print it. Scanning single tokens alone missed the
            // commonest form entirely, so the whole feature never fired.
            if index + 1 < tokens.count, isFlightNumber(token + tokens[index + 1]) {
                return true
            }
        }
        return false
    }

    /// Two characters including at least one letter — IATA airline codes are two
    /// characters — then two to five digits.
    private static func isFlightNumber(_ word: String) -> Bool {
        guard (4...7).contains(word.count) else { return false }

        let prefix = word.prefix(2)
        let rest = word.dropFirst(2)

        return prefix.allSatisfy { $0.isLetter || $0.isNumber }
            && prefix.contains(where: \.isLetter)
            && (2...5).contains(rest.count)
            && rest.allSatisfy(\.isNumber)
    }

    // MARK: - Verification

    /// The pass with every unverifiable field blanked, or `nil` if not even the
    /// flight number could be found.
    ///
    /// The flight is the one field worth failing over — a pass with no gate
    /// printed on it yet is completely normal, a pass whose flight number is not
    /// on the page means the model invented the whole thing.
    static func verified(_ pass: BoardingPass, against text: String) -> BoardingPass? {
        let source = normalised(text)

        let flight = pass.flight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flight.isEmpty, source.contains(normalised(flight)) else { return nil }

        return BoardingPass(
            flight: flight,
            from: found(pass.from, in: source),
            to: found(pass.to, in: source),
            gate: found(pass.gate, in: source),
            seat: found(pass.seat, in: source),
            boards: found(pass.boards, in: source)
        )
    }

    private static func found(_ field: String, in source: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, source.contains(normalised(trimmed)) else { return "" }
        return trimmed
    }

    /// Case and spacing removed, so "6E 5231" matches "6E5231" — tolerant of how
    /// a value is written, intolerant of one that is not there.
    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    // MARK: - Saying it

    /// Composed in Swift from verified fields only, and kept to the things you
    /// actually need at a barrier: which flight, which gate, when.
    static func sentence(for pass: BoardingPass) -> String {
        var line = "That's \(pass.flight)"

        if !pass.to.isEmpty {
            line += pass.from.isEmpty ? " to \(pass.to)" : " from \(pass.from) to \(pass.to)"
        }
        if !pass.seat.isEmpty { line += ", seat \(pass.seat)" }
        if !pass.gate.isEmpty { line += ", gate \(pass.gate)" }
        if !pass.boards.isEmpty { line += ", boarding \(pass.boards)" }

        return line + ", boss."
    }
}
