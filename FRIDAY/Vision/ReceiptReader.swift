import Foundation

/// Decides when a scan is worth extracting, and refuses to believe anything the
/// model did not actually find on the page.
///
/// The rule this whole file exists to enforce: **FRIDAY never states a fact she
/// cannot point at.** Guided generation gives a typed `Receipt` rather than a
/// string that needs parsing, but typed is not the same as true — the fields are
/// still whatever the model produced. So each one is looked up in the recognised
/// text before it is allowed into a sentence.
///
/// A field that fails is dropped, not repaired; the total failing drops the
/// whole extraction and the scan falls back to being summarised like any other
/// document. Saying less is always available, and is always better than saying
/// something wrong about the boss's money.
enum ReceiptReader {

    // MARK: - Is this even a receipt

    /// Cheap Swift test for whether an extraction pass is worth its seconds.
    ///
    /// Deterministic and free, so the model is never asked to decide whether it
    /// should be asked — the same division of labour as `Router`. Both halves
    /// are required: "total" alone matches an essay about totals, and a currency
    /// amount alone matches a price on a poster.
    static func looksLikeReceipt(_ text: String) -> Bool {
        let lowered = text.lowercased()

        let billing = ["total", "subtotal", "amount", "balance due", "amount paid",
                       "net payable", "invoice", "receipt", "bill no", "gst", "vat",
                       "tax", "change due", "cash", "card ending"]
        guard billing.contains(where: lowered.contains) else { return false }

        return containsCurrencySymbol(text) || containsDecimalAmount(text)
    }

    private static func containsCurrencySymbol(_ text: String) -> Bool {
        text.contains { "₹$£€¥₩฿".contains($0) }
    }

    /// A run of digits, a separator, then exactly two digits — "47.30", "1240,00".
    /// Prices are written this way and prose is not.
    private static func containsDecimalAmount(_ text: String) -> Bool {
        let digits = Array(text)
        for index in digits.indices where digits[index] == "." || digits[index] == "," {
            let before = index > digits.startIndex ? digits[index - 1].isNumber : false
            let twoAfter = index + 2 < digits.count
                && digits[index + 1].isNumber
                && digits[index + 2].isNumber
            let notThree = index + 3 >= digits.count || !digits[index + 3].isNumber
            if before && twoAfter && notThree { return true }
        }
        return false
    }

    // MARK: - Verification

    /// The receipt with every unverifiable field blanked, or `nil` if the total
    /// itself could not be found in the page.
    ///
    /// The total is the one field that cannot degrade: a receipt without a
    /// merchant is still worth saying, a receipt with the wrong number is worse
    /// than no receipt at all.
    static func verified(_ receipt: Receipt, against text: String) -> Receipt? {
        let total = receipt.total.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !total.isEmpty, isTheTotal(total, in: text) else { return nil }

        let source = normalised(text)
        return Receipt(
            merchant: found(receipt.merchant, in: source),
            date: found(receipt.date, in: source),
            total: total
        )
    }

    /// The total must sit on a line that *says* it is the total.
    ///
    /// Searching the whole page is not enough, and the difference matters. A
    /// page-wide search proves only that the number was printed somewhere — so a
    /// model that returned the tax line, or the subtotal, or the cash tendered
    /// would pass, and FRIDAY would state a real number that is the wrong
    /// answer. Requiring the label pins *which* number it is.
    ///
    /// A receipt that puts its total on the following line fails this and falls
    /// back to the ordinary summary. That is the right way round: a missed
    /// extraction costs a nicety, a wrong one misreports what he spent.
    private static func isTheTotal(_ total: String, in text: String) -> Bool {
        let wanted = normalised(total)
        return text.split(whereSeparator: \.isNewline).contains { line in
            announcesTotal(String(line)) && normalised(String(line)).contains(wanted)
        }
    }

    /// "subtotal" is stripped before matching rather than listed as an
    /// exclusion, because it *contains* "total" — without this, a subtotal reads
    /// as the amount paid, which on the receipt above is 1043.50 against a real
    /// total of 1,240.00.
    private static func announcesTotal(_ line: String) -> Bool {
        let cleaned = line.lowercased()
            .replacingOccurrences(of: "subtotal", with: "")
            .replacingOccurrences(of: "sub total", with: "")
        return ["total", "amount due", "amount paid", "balance due", "net payable"]
            .contains(where: cleaned.contains)
    }

    /// The field back if it is genuinely in the page, otherwise empty.
    private static func found(_ field: String, in source: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, source.contains(normalised(trimmed)) else { return "" }
        return trimmed
    }

    /// Case, whitespace and thousands separators removed.
    ///
    /// Tolerant of how a value is *written* — "₹ 1,240" and "₹1240" are the same
    /// number — and intolerant of a value that is not there at all, which is the
    /// only distinction that matters here.
    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "," }
    }

    // MARK: - Saying it

    /// The spoken line, composed in Swift from verified fields only.
    ///
    /// Composed here rather than by the model for D-44's reason: the model has
    /// already had its turn, and letting it write the sentence would hand back
    /// the number it was just checked on.
    static func sentence(for receipt: Receipt) -> String {
        var line = "That's \(receipt.total)"
        if !receipt.merchant.isEmpty { line += " at \(receipt.merchant)" }
        if !receipt.date.isEmpty { line += " on \(receipt.date)" }
        return line + ", boss."
    }
}
