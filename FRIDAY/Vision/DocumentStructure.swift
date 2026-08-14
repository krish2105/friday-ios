import Foundation
import Vision

/// Keeps a table a table.
///
/// `TextScanner` has claimed since stage 1 that "tables stay tables and lists
/// stay lists" — and it flattened everything to `Container.text.transcript`,
/// which is one long string with the shape thrown away. The comment described a
/// design the code did not implement, which is the same defect this project
/// found once before in the translation router. This makes the comment true.
///
/// It matters because of what happens next. The recognised text is handed to a
/// ~3B model, and a flattened table is genuinely ambiguous: a receipt reading
///
///     Flat white 3.40 Croissant 2.80 Total 6.20
///
/// gives the model no way to know whether `3.40` belongs to the flat white or to
/// the croissant. Rows and columns are the difference between reading a bank
/// statement and guessing at one.
enum DocumentStructure {

    /// The document as text, with tables and lists kept in shape.
    ///
    /// When a page has neither, this returns **exactly** `text.transcript` — the
    /// behaviour every earlier stage was built and tested against. Structure is
    /// added where it exists and nothing changes where it does not.
    static func transcript(of container: DocumentObservation.Container) -> String {
        let tables = container.tables.map(render)
        let lists = container.lists.map(render)

        guard !tables.isEmpty || !lists.isEmpty else {
            return container.text.transcript
        }

        // Vision reports a table's text *twice*: once inside `tables`, and again
        // as part of the flat transcript. Emitting both would hand the model the
        // receipt in structured form and then immediately contradict it with the
        // flattened one. So the flat lines that a cell already accounts for are
        // dropped, and whatever prose surrounded the table survives.
        let claimed = Set(
            (container.tables.flatMap { $0.rows.flatMap { $0 } }.map { cellText($0) }
             + container.lists.flatMap(\.items).map { $0.itemString })
                .map(normalised)
                .filter { !$0.isEmpty }
        )

        let prose = container.text.transcript
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let key = normalised(line)
                return !key.isEmpty && !claimed.contains(key)
            }

        return (prose + tables + lists)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A table as aligned columns.
    ///
    /// Plain spaces rather than pipes or Markdown. The output is read by a
    /// language model *and* shown to the boss verbatim, and a wall of `|` reads
    /// as machinery in a conversation — alignment carries the same information
    /// and looks like a receipt.
    private static func render(_ table: DocumentObservation.Container.Table) -> String {
        let grid = table.rows.map { $0.map(cellText) }
        guard !grid.isEmpty else { return "" }

        // Widths from the widest cell in each column, so a narrow column does not
        // get padded out to match a wide one three columns over.
        let columnCount = grid.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columnCount)
        for row in grid {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }

        return grid.map { row in
            row.enumerated()
                .map { index, cell in
                    // The last column is never padded — trailing spaces on every
                    // line is invisible noise that still costs model context.
                    index == row.count - 1
                        ? cell
                        : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
                }
                .joined(separator: "   ")
                .trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
    }

    /// A list with its markers kept.
    ///
    /// `markerString` is what was actually printed — "1.", "•", "a)" — so an
    /// ordered list stays ordered rather than becoming a bag of lines.
    private static func render(_ list: DocumentObservation.Container.List) -> String {
        list.items
            .map { item in
                let marker = item.markerString.trimmingCharacters(in: .whitespaces)
                let body = item.itemString.trimmingCharacters(in: .whitespaces)
                return marker.isEmpty ? "• \(body)" : "\(marker) \(body)"
            }
            .joined(separator: "\n")
    }

    /// A cell's text, flattened one level.
    ///
    /// `Cell.content` is a `Container` in its own right, so a cell can in
    /// principle hold another table. That is not flattened recursively on
    /// purpose: a nested table inside a receipt cell is not a thing that happens,
    /// and unbounded recursion over untrusted input is a hang waiting for the one
    /// page that does.
    private static func cellText(_ cell: DocumentObservation.Container.Table.Cell) -> String {
        cell.content.text.transcript
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Case- and space-insensitive, for matching a flat line against a cell.
    private static func normalised(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
