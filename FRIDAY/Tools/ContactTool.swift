import Contacts
import Foundation
import Observation

/// A contact reduced to the fields FRIDAY uses — and to values that can cross an
/// isolation boundary.
///
/// `CNContact` is not `Sendable`, so it must never leave the queue that fetched
/// it. Mapping to this on the way out is the same discipline the pedometer uses:
/// take what you need where the work lands, and carry nothing else back.
///
/// It also makes the matching below **pure**, so "does *mom* find the right
/// person" is answerable in a test with fixtures rather than only on a device
/// with a real address book.
struct Person: Sendable, Identifiable, Equatable {
    struct Relation: Sendable, Equatable {
        /// The label as filed — "mother", "spouse", "brother".
        var label: String
        /// Who it points at.
        var name: String
    }

    var id: String
    var name: String
    var nickname: String
    var number: String?
    var email: String?
    var birthday: DateComponents?
    var relations: [Relation]
}

/// Reads the address book. Nothing here writes.
enum ContactBook {
    /// Computed, not stored. `[CNKeyDescriptor]` is not `Sendable`, so a
    /// `static let` is global mutable state the compiler rightly refuses; built
    /// per call it is owned by the caller and crosses nothing.
    private static var keys: [CNKeyDescriptor] {
        [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactNicknameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactBirthdayKey, CNContactRelationsKey
        ].map { $0 as CNKeyDescriptor }
    }

    static func authorised() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return true }
        guard status == .notDetermined else { return false }
        return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Everyone, as `Person` values.
    ///
    /// `enumerateContacts` rather than a predicate, because the matching is
    /// wider than any `CNContact` predicate supports — nicknames and *other
    /// people's* relation labels are not searchable fields.
    static func everyone() async -> [Person] {
        await Task.detached {
            var found: [Person] = []
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: request) { contact, _ in
                found.append(Person(
                    id: contact.identifier,
                    name: displayName(contact),
                    nickname: contact.nickname,
                    number: contact.phoneNumbers.first?.value.stringValue,
                    email: contact.emailAddresses.first?.value as String?,
                    birthday: contact.birthday,
                    relations: contact.contactRelations.map {
                        Person.Relation(label: $0.label ?? "", name: $0.value.name)
                    }
                ))
            }
            return found
        }.value
    }

    private static func displayName(_ contact: CNContact) -> String {
        let full = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        if !full.isEmpty { return full }
        if !contact.nickname.isEmpty { return contact.nickname }
        return contact.organizationName
    }
}

/// Matching a spoken name to a person. Pure, and therefore testable.
///
/// "Mom" is almost never how a contact is filed, so four routes are tried and
/// the first that finds anything wins. They are ordered by how specific the
/// evidence is — an explicit nickname beats a fuzzy prefix.
enum ContactMatcher {

    /// Spoken words for a relationship, mapped onto the labels iOS actually
    /// files them under.
    ///
    /// This is the difference between the feature working and not. Nobody sets
    /// a related name labelled "mom" — the Contacts app offers **"mother"** —
    /// so matching the spoken word against the stored label directly resolves
    /// "mother" and fails on "mom", which is the only one anyone says out loud.
    ///
    /// The Hindi terms are here because the app is bilingual as of D-56, and
    /// "bhai" is as likely as "brother" from someone typing Devanagari.
    private static let relationSynonyms: [String: [String]] = [
        "mother": ["mom", "mum", "mummy", "mommy", "ma", "amma", "maa", "mataji"],
        "father": ["dad", "daddy", "papa", "pa", "pop", "pitaji"],
        "spouse": ["wife", "husband", "partner"],
        "brother": ["bro", "bhai", "bhaiya"],
        "sister": ["sis", "behen", "didi"],
        "child": ["son", "daughter", "kid"],
        "friend": ["mate", "buddy"]
    ]

    /// Every relation label a spoken word could mean, including itself.
    static func relationLabels(for wanted: String) -> [String] {
        var labels = [wanted]
        for (label, spoken) in relationSynonyms where spoken.contains(wanted) {
            labels.append(label)
        }
        return labels
    }

    static func matches(for spokenName: String, in everybody: [Person]) -> [Person] {
        let wanted = spokenName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }

        // 1. A nickname is unambiguous when it has been set.
        let byNickname = everybody.filter { $0.nickname.lowercased() == wanted }
        if !byNickname.isEmpty { return byNickname }

        // 2. A relation label on *anyone's* card — which is where iOS actually
        //    files "mother", via the Contacts app's "add related name". The card
        //    carrying the label is usually his own, but nothing here depends on
        //    that, so a relation filed anywhere still resolves.
        let labels = relationLabels(for: wanted)
        let relatedNames = everybody
            .flatMap(\.relations)
            .filter { relation in
                let stored = relation.label.lowercased()
                return labels.contains { stored.contains($0) }
            }
            .map { $0.name.lowercased() }

        if !relatedNames.isEmpty {
            let byRelation = everybody.filter { relatedNames.contains($0.name.lowercased()) }
            if !byRelation.isEmpty { return byRelation }
        }

        // 3. An exact name.
        let exact = everybody.filter {
            $0.name.lowercased() == wanted
                || $0.name.lowercased().split(separator: " ").first.map(String.init) == wanted
        }
        if !exact.isEmpty { return exact }

        // 4. A prefix, last and least. Contained-anywhere would match far too
        //    much — "ann" inside "Joanna" is not a person called Ann.
        return everybody.filter { $0.name.lowercased().hasPrefix(wanted) }
    }

    /// The next birthday due, across everyone.
    ///
    /// Sorted by days away rather than by date, because a birthday in January is
    /// the *next* one when today is December.
    static func nextBirthday(
        in everybody: [Person],
        after today: Date,
        calendar: Calendar = .current
    ) -> (name: String, date: Date, days: Int)? {
        everybody
            .compactMap { person -> (name: String, date: Date, days: Int)? in
                guard let birthday = person.birthday,
                      let next = nextOccurrence(of: birthday, onOrAfter: today, calendar: calendar)
                else { return nil }
                let days = calendar.dateComponents([.day], from: today, to: next).day ?? 0
                return (person.name, next, days)
            }
            .min { $0.days < $1.days }
    }

    static func nextOccurrence(
        of birthday: DateComponents,
        onOrAfter today: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let month = birthday.month, let day = birthday.day else { return nil }
        let thisYear = calendar.component(.year, from: today)

        for year in [thisYear, thisYear + 1] {
            if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
               date >= today {
                return date
            }
        }
        return nil
    }
}

/// Looks people up, and stages a call rather than placing one.
///
/// **The model never sees a contact.** The name is matched in Swift and the
/// answer is composed in Swift, so nobody's number or birthday ever enters a
/// prompt. That is D-44 where it matters most: a ~3B model paraphrasing a phone
/// number is not a wrong answer, it is a wrong person.
@MainActor
@Observable
final class ContactService {

    enum Aspect: Equatable, Sendable {
        case number
        case email
        case birthday
    }

    /// A call FRIDAY has offered but not placed. `Router` has known phrasing
    /// gaps, and a false positive that dials a real person at two in the morning
    /// is not a failure worth risking to save one tap (D-34).
    struct PendingCall: Identifiable, Equatable, Sendable {
        let id = UUID()
        var name: String
        var number: String
    }

    private(set) var pendingCall: PendingCall?

    func cancelCall() {
        pendingCall = nil
    }

    // MARK: - Answering

    func answer(for spokenName: String, aspect: Aspect, offeringCall: Bool) async -> String {
        guard await ContactBook.authorised() else {
            return "I can't see your contacts, boss. You can switch that on in Settings, under FRIDAY."
        }

        let matches = ContactMatcher.matches(for: spokenName, in: await ContactBook.everyone())

        guard !matches.isEmpty else {
            return "I can't find \(spokenName) in your contacts, boss."
        }

        // Ambiguity is asked about, never guessed at. Taking the first of two
        // Rajs is how you ring the wrong one.
        guard matches.count == 1 else {
            let names = matches.prefix(3).map(\.name).joined(separator: " or ")
            return "I've got a few, boss — \(names)?"
        }

        let person = matches[0]

        switch aspect {
        case .number:
            guard let number = person.number else {
                return "I've got \(person.name), boss, but no number for them."
            }
            if offeringCall {
                pendingCall = PendingCall(name: person.name, number: number)
                return "That's \(person.name), \(number), boss. Say the word and I'll dial."
            }
            return "\(person.name) is on \(number), boss."

        case .email:
            guard let email = person.email else {
                return "I've got \(person.name), boss, but no email for them."
            }
            return "\(person.name) is at \(email), boss."

        case .birthday:
            guard let components = person.birthday,
                  let date = Calendar.current.date(from: components) else {
                return "There's no birthday saved for \(person.name), boss."
            }
            return "\(person.name)'s birthday is \(date.formatted(.dateTime.day().month(.wide))), boss."
        }
    }

    func nextBirthday() async -> String {
        guard await ContactBook.authorised() else {
            return "I can't see your contacts, boss. You can switch that on in Settings, under FRIDAY."
        }

        let today = Calendar.current.startOfDay(for: Date())
        guard let next = ContactMatcher.nextBirthday(in: await ContactBook.everyone(), after: today)
        else {
            return "I can't find any birthdays saved, boss."
        }

        let when = switch next.days {
        case 0: "today"
        case 1: "tomorrow"
        default: "in \(next.days) days, on \(next.date.formatted(.dateTime.day().month(.wide)))"
        }
        return "\(next.name)'s birthday is \(when), boss."
    }
}
