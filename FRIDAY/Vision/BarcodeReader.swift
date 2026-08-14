import Foundation
import Vision

/// Reads QR codes and barcodes, and works out what one actually says.
///
/// **A code is untrusted input from the physical world.** Anyone can print a QR
/// sticker and put it on a parking meter, so nothing here follows a link, joins
/// a network or adds a contact. FRIDAY reads out what the code contains and
/// shows the whole thing; opening it takes a deliberate press, on a card that
/// displays the **full** address rather than a friendly name. That is D-34's
/// rule applied to a threat D-34 did not anticipate.
///
/// One deliberate omission: a Wi-Fi code's password is parsed but never spoken
/// or displayed. Reading a password aloud in a room is not a feature.
enum BarcodeReader {

    /// What a code turned out to be.
    enum Payload: Equatable, Sendable {
        case link(URL)
        case wifi(network: String)
        case contact(name: String)
        case text(String)
    }

    /// Every code found across the pages, most confident first.
    static func codes(in pages: [Data]) async -> [String] {
        var found: [(payload: String, confidence: Float)] = []

        for page in pages {
            guard let observations = try? await DetectBarcodesRequest().perform(on: page) else {
                continue
            }
            found += observations.compactMap { observation in
                guard let payload = observation.payloadString, !payload.isEmpty else { return nil }
                return (payload, observation.confidence)
            }
        }

        return found
            .sorted { $0.confidence > $1.confidence }
            .map(\.payload)
    }

    // MARK: - Making sense of a payload

    static func classify(_ payload: String) -> Payload {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.uppercased().hasPrefix("WIFI:") {
            return .wifi(network: field("S", in: trimmed) ?? "an unnamed network")
        }

        if trimmed.uppercased().hasPrefix("BEGIN:VCARD") {
            return .contact(name: vCardName(in: trimmed) ?? "someone")
        }

        // `http` and `https` only. A `javascript:` or `data:` payload is not
        // something to hand to the system, and anything else is read as text.
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host() != nil {
            return .link(url)
        }

        return .text(trimmed)
    }

    /// A `WIFI:S:name;T:WPA;P:secret;;` field. The password field is reachable
    /// by this and deliberately never asked for.
    private static func field(_ key: String, in payload: String) -> String? {
        for part in payload.dropFirst("WIFI:".count).split(separator: ";") {
            let piece = String(part)
            guard piece.uppercased().hasPrefix("\(key):") else { continue }
            let value = piece.dropFirst(key.count + 1)
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private static func vCardName(in payload: String) -> String? {
        for line in payload.split(whereSeparator: \.isNewline) {
            guard line.uppercased().hasPrefix("FN:") else { continue }
            let name = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    // MARK: - Saying it

    /// What FRIDAY says, composed in Swift.
    ///
    /// A link is described by its **host**, not its full address — reading a
    /// tracking-laden URL aloud helps nobody. The whole address goes on the
    /// confirmation card, where it can be read before anything is opened.
    static func sentence(for payload: Payload) -> String {
        switch payload {
        case .link(let url):
            "That's a link to \(url.host() ?? "somewhere"), boss. Say the word and I'll open it."
        case .wifi(let network):
            "That's Wi-Fi details for \(network), boss."
        case .contact(let name):
            "That's a contact card for \(name), boss."
        case .text(let text):
            "It says: \(text)"
        }
    }
}
