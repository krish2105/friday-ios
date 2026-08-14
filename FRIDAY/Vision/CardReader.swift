import Contacts
import Foundation

/// Business cards, and the staged write that follows.
///
/// The third document type built on the same shape as `ReceiptReader` and
/// `BoardingPassReader` — cheap Swift gate, model selects, Swift refuses
/// anything not on the page — and by now that shape is the point rather than
/// any one document.
///
/// The stakes are different here though. A receipt is read aloud and forgotten;
/// **a card is written into the address book**, where a wrong digit becomes a
/// person you can never reach and will not know you cannot reach. So the
/// verification is stricter: a name that cannot be found is fatal, not blanked.
enum CardReader {

    // MARK: - Is this a card

    /// Cards are short and contain a way to reach someone. Both are required:
    /// a letterhead has contact details and pages of text; a poster is short and
    /// has neither.
    static func looksLikeCard(_ text: String) -> Bool {
        guard text.count <= 400 else { return false }
        return containsEmail(text) || containsPhone(text)
    }

    private static func containsEmail(_ text: String) -> Bool {
        text.split(whereSeparator: { $0 == " " || $0.isNewline }).contains { token in
            guard let at = token.firstIndex(of: "@") else { return false }
            let domain = token[token.index(after: at)...]
            return at != token.startIndex && domain.contains(".") && !domain.hasSuffix(".")
        }
    }

    /// Seven or more digits once separators are stripped — the shortest thing
    /// anyone would call a phone number.
    private static func containsPhone(_ text: String) -> Bool {
        var run = 0
        for character in text {
            if character.isNumber {
                run += 1
                if run >= 7 { return true }
            } else if !" -()+.".contains(character) {
                run = 0
            }
        }
        return false
    }

    // MARK: - Verification

    /// The card with unverifiable fields blanked, or `nil` if the **name** is
    /// not on the page.
    ///
    /// A card with no company is ordinary; a card whose name the model invented
    /// is a fabricated person about to be saved to the phone.
    static func verified(_ card: BusinessCard, against text: String) -> BusinessCard? {
        let source = normalised(text)

        let name = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, source.contains(normalised(name)) else { return nil }

        return BusinessCard(
            name: name,
            organisation: found(card.organisation, in: source),
            phone: found(card.phone, in: source),
            email: found(card.email, in: source)
        )
    }

    private static func found(_ field: String, in source: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, source.contains(normalised(trimmed)) else { return "" }
        return trimmed
    }

    /// Case, whitespace and the punctuation people scatter through phone numbers
    /// removed — so "+91 98200 11111" matches "+919820011111" — while an invented
    /// digit still fails.
    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !"-()..,".contains($0) }
    }

    // MARK: - Saying it

    static func sentence(for card: BusinessCard) -> String {
        var line = "That's \(card.name)"
        if !card.organisation.isEmpty { line += " at \(card.organisation)" }
        line += ", boss. Say the word and I'll save them."
        return line
    }

    static func detail(for card: BusinessCard) -> String {
        [card.organisation, card.phone, card.email]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: - Writing

    /// The only path that adds a contact, and it is reachable solely from a
    /// button (D-34). Returns what FRIDAY should say.
    static func save(_ card: BusinessCard) async -> String {
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else {
            return "I can't add contacts without access, boss. You can switch it on in Settings, under FRIDAY."
        }

        let contact = CNMutableContact()
        let parts = card.name.split(separator: " ")
        contact.givenName = parts.first.map(String.init) ?? card.name
        contact.familyName = parts.dropFirst().joined(separator: " ")
        contact.organizationName = card.organisation

        if !card.phone.isEmpty {
            contact.phoneNumbers = [
                CNLabeledValue(label: CNLabelPhoneNumberMobile,
                               value: CNPhoneNumber(stringValue: card.phone))
            ]
        }
        if !card.email.isEmpty {
            contact.emailAddresses = [
                CNLabeledValue(label: CNLabelWork, value: card.email as NSString)
            ]
        }

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)

        do {
            try store.execute(request)
            return "Saved \(card.name) to your contacts, boss."
        } catch {
            return "Couldn't save that one, boss. Want me to try again?"
        }
    }
}
