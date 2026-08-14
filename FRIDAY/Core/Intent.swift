import Foundation

/// What the boss asked for, decided in Swift rather than by the model.
///
/// The on-device model is ~3B parameters. On this device it routed "what time
/// is it" to the reminder tool, "what can you do" to the battery tool, and
/// staged a reminder titled "What time is it?". Three rounds of tightening tool
/// descriptions and persona rules did not fix it, because tool selection is
/// simply not something a model this size does reliably with several tools in
/// play.
///
/// So routing is no longer the model's job. Code decides which tool runs, and
/// the model is left with the one thing it is genuinely good at: phrasing a
/// conversational reply. A tool can no longer fire on a turn that was not
/// routed to it, which makes the whole class of mis-routing impossible rather
/// than merely less likely.
enum Intent: Equatable {
    case time(includeDate: Bool)
    case device(aspect: String)
    case calendar(day: String)
    case reminder(title: String, when: String)
    /// Put something in the calendar. Staged, never written outright (D-34).
    case event(title: String, when: String)
    /// Look someone up. `callable` means the phrasing asked to reach them, so
    /// the answer offers a dial button rather than only reading the number out.
    case contact(name: String, aspect: ContactService.Aspect, callable: Bool)
    /// Whose birthday is next, across the whole address book.
    case nextBirthday
    /// Steps, distance or stairs. `dayOffset` is 0 for today, -1 for yesterday.
    case motion(aspect: MotionTool.Aspect, dayOffset: Int)
    /// "How do you say ‹phrase› in ‹language›." `code` is a language code.
    case translate(phrase: String, code: String)
    /// "Set a timer for ten minutes."
    case timer(seconds: Int)
    /// Arithmetic, a percentage or a unit conversion — worked out in Swift.
    case reckon(ReckonTool.Sum)
    /// "What's on my clipboard."
    case clipboard
    /// "Translate into French" — stay in translation until told to stop.
    case startTranslating(code: String)
    case stopTranslating
    /// Read whatever he's about to show me. Nothing to look up here — the image
    /// comes from the UI, so `FridayEngine.scan` does the work.
    case scan(source: ScanSource, purpose: ScanPurpose = .read)
    /// Nothing to look up — hand it to the model.
    case chat
}

/// What to do with the words once they're off the page.
///
/// Carried on the intent rather than inferred later, because by the time the
/// photo comes back from the picker the sentence that asked for it is gone.
enum ScanPurpose: Equatable {
    /// The existing behaviour: read it, and offer a receipt or a boarding pass
    /// if that is what it turns out to be.
    case read
    /// Put it into this language first. `code` is a language code.
    case translate(code: String)
}

/// Where the picture comes from.
enum ScanSource: Equatable {
    /// He's holding the thing up. Point the camera at it.
    case camera
    /// It's already on the phone.
    case library
    /// It's a file — a PDF in Files, iCloud Drive, or an attachment saved off.
    case files
    /// A code or a sign in the world. Live viewfinder, tap what you mean —
    /// no shutter, no page edges, because neither applies to a QR sticker.
    case live
}

enum Router {
    /// Order matters. Reminders are checked first because "remind me at six"
    /// also contains time words, and a mis-order there would answer the clock
    /// instead of staging the reminder.
    static func intent(for input: String) -> Intent {
        let text = input.lowercased()

        if contains(text, ["remind me", "reminder", "remember to", "don't let me forget"]) {
            return .reminder(title: reminderTitle(from: input), when: input)
        }

        // Leaving the mode is checked before anything else, because while it is
        // on every other turn is being translated rather than routed — and a way
        // out that can itself be swallowed is not a way out.
        if contains(text, ["stop translating", "stop translation", "stop the translation",
                           "done translating", "back to normal", "normal mode"]) {
            return .stopTranslating
        }

        // Translating something he is *holding up*. The most specific of the
        // three translation shapes, so it is asked first — and that order is
        // measured rather than reasoned. Placed after `translationRequest` below,
        // "translate this menu into Hindi" came back as a request to translate
        // the literal words "this menu", because a sight noun reads perfectly
        // well as a phrase. Placed after mode entry it would be swallowed whole,
        // since "translate this menu" contains no phrase either — the same shape
        // as the bug that lost "translate into Hindi where is the station", one
        // rung further down.
        //
        // The gate is deliberately narrow: a demonstrative *and* a word for a
        // thing you can point a camera at. "Translate this into Hindi" is left
        // alone and still enters mode, because with no such noun it is genuinely
        // ambiguous and the existing reading is the established one.
        if let sight = sightTranslation(in: text) {
            return sight
        }

        // A one-shot: "how do you say good morning in French". Before the mode
        // and before the rest of the table, because a translation request can
        // contain any words at all — "how do you say what time is it in French"
        // would otherwise be answered with the time.
        if let translation = translationRequest(in: input) {
            return translation
        }

        // Entering the mode, and this **must** come after the one-shot rather
        // than before it. Mode is defined as a translation request with no
        // phrase in it, so it can only be recognised once the attempt to find a
        // phrase has failed. Checked first, it swallowed "translate into Hindi
        // where is the station" whole and threw the phrase away.
        if contains(text, ["translate into", "translate to", "translating into",
                           "translating to", "translation mode", "speak in", "talk in"]),
           let named = Tongues.firstNamed(in: text) {
            return .startTranslating(code: named.code)
        }

        // Before reminders: "set a timer for ten minutes" is not a reminder, but
        // it is close enough in shape that the reminder needles would take it.
        if contains(text, ["set a timer", "start a timer", "timer for", "time me for"]) {
            guard let seconds = TimerTool.seconds(in: text) else {
                // A timer with no duration is a question, not a failure.
                return .chat
            }
            return .timer(seconds: seconds)
        }

        if contains(text, ["clipboard", "what did i copy", "what i copied", "paste"]) {
            return .clipboard
        }

        if let sum = reckoning(in: text) {
            return .reckon(sum)
        }

        // Writing to the calendar is checked before *reading* it, because
        // "schedule" appears in both and answering "schedule lunch at one" with
        // today's agenda is the wrong half of the word.
        if let event = eventRequest(in: text, original: input) {
            return event
        }

        // Before the device aspects: "whose birthday is next" contains no device
        // word, but "call mom" would fall to chat if contacts came later than
        // the broader needles below.
        if contains(text, ["whose birthday", "next birthday", "birthday next",
                           "any birthdays", "whos birthday"]) {
            return .nextBirthday
        }

        if let contact = contactRequest(in: text, original: input) {
            return contact
        }

        if let motion = motionRequest(in: text) {
            return .motion(aspect: motion.aspect, dayOffset: motion.dayOffset)
        }

        // Every needle carries a demonstrative — "this", "that", "it". A bare
        // "read" or "scan" would catch "did you read the news" and "scan the
        // calendar for me", and putting a picker up on those is a much worse
        // failure than falling through to chat.
        if contains(text, ["read this", "read that", "read it", "scan this", "scan that",
                           "what does this say", "what does that say", "what does it say",
                           "what's this say", "whats this say", "what's it say", "whats it say",
                           "what's this code", "whats this code", "scan a code", "scan the code",
                           "read this pdf", "open this pdf"]) {
            return .scan(source: scanSource(in: text))
        }

        // A code gets its own rule because it is asked about in ways that dodge
        // both of the others: "what's this QR code" has a noun wedged in *and*
        // no "say" to anchor on. The noun is specific enough to route on when
        // paired with an asking word — nobody says "barcode" in passing.
        if contains(text, ["qr code", "qr-code", "barcode", "bar code"]),
           contains(text, ["this", "that", "scan", "read", "what"]),
           !contains(text, ["what is a", "what's a", "whats a", "how does a"]) {
            return .scan(source: .live)
        }

        // The same question with a noun wedged into it — "what does this receipt
        // say", "what does that sign say" — slips past a contiguous needle, and
        // the nouns are open-ended enough that listing them is hopeless. So the
        // demonstrative and the verb are matched separately, and *both* are
        // required: that is what keeps "what does that mean" out.
        if contains(text, ["what does this", "what does that", "what's this", "whats this"]),
           contains(text, [" say", "says"]) {
            return .scan(source: scanSource(in: text))
        }

        if let aspect = deviceAspect(in: text) {
            return .device(aspect: aspect)
        }

        if contains(text, ["calendar", "schedule", "agenda", "my meetings", "next meeting",
                           "what's on today", "whats on today", "what's on my day",
                           "do i have anything", "anything on today", "anything on tomorrow"]) {
            return .calendar(day: text.contains("tomorrow") ? "tomorrow" : "today")
        }

        // "what time" and "the time" are safe; a bare "time" is not — "do I have
        // time for coffee" must stay a conversation.
        if contains(text, ["what time", "the time", "what's the time", "whats the time",
                           "current time", "time is it", "clock"]) {
            return .time(includeDate: false)
        }

        if contains(text, ["what date", "what's the date", "whats the date",
                           "what day", "today's date"]) {
            return .time(includeDate: true)
        }

        return .chat
    }

    // MARK: - Pieces

    private static func contains(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// Needles are deliberately multi-word where a single word would over-match.
    /// "hot" alone sent "how hot is it outside" — a weather question — to the
    /// phone's thermal state, and "space" alone caught every mention of space.
    /// A missed route falls through to chat, which is a far better failure than
    /// confidently answering the wrong question.
    private static func deviceAspect(in text: String) -> String? {
        if contains(text, ["battery", "charging", "charged", "power left", "how much power"]) {
            return "battery"
        }
        if contains(text, ["storage", "disk space", "free space", "space left", "memory left", "how much space"]) {
            return "storage"
        }
        if contains(text, ["wifi", "wi-fi", "network", "am i online", "connection", "internet", "signal"]) {
            return "network"
        }
        if contains(text, ["temperature", "thermal", "overheat", "running hot", "how hot is the phone"]) {
            return "temperature"
        }
        return nil
    }

    /// The camera unless he named something already on the phone.
    ///
    /// "Read this" with nothing else in it means he's holding a page up, and
    /// making him go via the photo library to read a page in his hand is the
    /// wrong default for something meant to be a daily driver.
    ///
    /// The needles are possessive on purpose. A bare "picture" would send "take
    /// a picture of this and read it" to the photo library, which is the exact
    /// opposite of what was asked.
    private static func scanSource(in text: String) -> ScanSource {
        // A code is live: it is stuck to something in the world, and a shutter
        // plus perspective correction would only get in the way.
        if contains(text, ["qr code", "qr", "barcode", "bar code", "this code", "that code"]) {
            return .live
        }
        if contains(text, ["pdf", "this file", "that file", "this document",
                           "that document", "in files"]) {
            return .files
        }
        if contains(text, ["this photo", "that photo", "this picture", "that picture",
                           "this screenshot", "that screenshot", "this image", "that image",
                           "my photos", "camera roll", "photo library"]) {
            return .library
        }
        return .camera
    }

    // MARK: - Reckoning

    /// A sum, a percentage or a conversion — or nil, which is most sentences.
    ///
    /// Every branch requires a **digit** as well as its keyword, which is what
    /// keeps "what percentage of people agree" and "how far is the moon" out.
    /// A question about arithmetic is not a sum.
    private static func reckoning(in text: String) -> ReckonTool.Sum? {
        guard text.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }

        // "15% of 4200", "15 percent of 4200"
        if let percent = number(before: ["%", " percent", " per cent"], in: text),
           let range = text.range(of: " of "),
           let total = firstNumber(in: String(text[range.upperBound...])) {
            return .percentage(percent, of: total)
        }

        // "12 miles in km", "convert 5 kg to pounds"
        for separator in [" in ", " to ", " into "] {
            guard let range = text.range(of: separator) else { continue }
            let left = String(text[text.startIndex..<range.lowerBound])
            let right = String(text[range.upperBound...])

            if let value = firstNumber(in: left),
               let from = lastWord(in: left), ReckonTool.unit(named: from) != nil,
               let to = firstWord(in: right), ReckonTool.unit(named: to) != nil {
                return .convert(value, from: from, to: to)
            }
        }

        // A bare sum. Requires an operator so a sentence containing a number is
        // never mistaken for one.
        if contains(text, ["what's ", "whats ", "what is ", "calculate ", "how much is "]),
           text.contains(where: { "+*/×÷".contains($0) })
            || (text.contains("-") && text.contains(where: \.isNumber)) {
            let expression = text
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "÷", with: "/")
                .drop { !($0.isNumber || $0 == "(" || $0 == "-") }
            if ReckonTool.evaluate(String(expression)) != nil {
                return .arithmetic(String(expression))
            }
        }

        return nil
    }

    private static func firstNumber(in text: String) -> Double? {
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." || $0 == "," }
        return Double(digits.replacingOccurrences(of: ",", with: ""))
    }

    private static func number(before markers: [String], in text: String) -> Double? {
        for marker in markers {
            guard let range = text.range(of: marker) else { continue }
            let before = text[text.startIndex..<range.lowerBound]
            let digits = before.reversed().prefix { $0.isNumber || $0 == "." }.reversed()
            if let value = Double(String(digits)) { return value }
        }
        return nil
    }

    private static func firstWord(in text: String) -> String? {
        text.split(separator: " ").first.map(String.init)
    }

    private static func lastWord(in text: String) -> String? {
        text.split(separator: " ").last.map(String.init)
    }

    // MARK: - Translation

    /// "How do you say good morning in French" → the phrase and `fr`.
    ///
    /// **Two independent gates, both required.** An opening that asks for a
    /// translation, *and* a word that is genuinely a language. Either alone
    /// over-matches badly: "what's the time in London" has the shape and no
    /// language, and "I'm learning French" has a language and no request.
    ///
    /// Checked before every other route because the phrase being translated can
    /// contain anything at all — "how do you say what time is it in French"
    /// would otherwise be answered with the time, which is both wrong and
    /// exactly the kind of confident mis-answer D-43 exists to prevent.
    /// Things you can point a camera at.
    ///
    /// Open-ended by nature, so this is not a closed world and is not trying to
    /// be — it is the evidence that "this" refers to something *in front of him*
    /// rather than to the conversation. Missing a noun costs a fallthrough to an
    /// ordinary scan, which reads the page anyway.
    private static let sightNouns = [
        "menu", "sign", "page", "label", "poster", "notice", "document",
        "letter", "receipt", "packet", "package", "bottle", "box", "board",
        "screen", "card", "paper", "book", "ingredients", "instructions",
        "leaflet", "form", "ticket", "plaque", "banner", "wrapper"
    ]

    /// "Translate this menu" — words on a thing he is holding up.
    ///
    /// Three gates, and all three are load-bearing:
    ///
    /// 1. **A translate cue**, or a named language attached to a "say". Without
    ///    this, "what does this sign say" — which today correctly *reads* the
    ///    sign — would start being translated into English, which is both wrong
    ///    and slower.
    /// 2. **A demonstrative**, the same back-reference rule the scan needles and
    ///    `ScanFollowUp` already use. It is what separates "translate this menu"
    ///    from "translate the menu I sent you".
    /// 3. **A sight noun**, or an explicit looking-at phrase. This is what keeps
    ///    "translate this into Hindi" out: with no noun it is genuinely
    ///    ambiguous between a held-up page and the conversation, and the
    ///    established reading wins rather than being quietly changed.
    ///
    /// The target defaults to English because that is what "translate this menu"
    /// means when said by someone who cannot read the menu.
    private static func sightTranslation(in text: String) -> Intent? {
        let named = Tongues.firstNamed(in: text)?.code

        let hasTranslateCue = contains(text, ["translate", "translation"])
        let hasSayInLanguage = named != nil && contains(text, [" say", "says", " read"])
        guard hasTranslateCue || hasSayInLanguage else { return nil }

        // "Translate what I'm looking at" names no object at all, so it satisfies
        // both gates on its own — it is *more* explicitly about the camera than
        // "translate this menu", not less.
        let lookingAt = contains(text, ["looking at", "in front of me", "point the camera",
                                        "with the camera", "through the camera"])

        let demonstrative = contains(text, ["this", "that", "it "]) || text.hasSuffix("it")
        guard demonstrative || lookingAt else { return nil }

        let hasNoun = sightNouns.contains { contains(text, [$0]) }
            || contains(text, ["this photo", "that photo", "this picture", "that picture",
                               "this screenshot", "that screenshot", "this image", "that image"])
        guard hasNoun || lookingAt else { return nil }

        // English unless he named something else. A language named *as the
        // source* — "translate this Hindi menu" — lands here too and would set
        // the target to Hindi, which is why `SightTranslator` reports
        // `.alreadyThere` rather than round-tripping: the detector, not the
        // sentence, is the authority on what the page is written in.
        return .scan(source: scanSource(in: text), purpose: .translate(code: named ?? "en"))
    }

    private static func translationRequest(in input: String) -> Intent? {
        let lowered = input.lowercased()

        let openings = ["how do you say ", "how do i say ", "how would you say ",
                        "how to say ", "translate ", "what's ", "whats ",
                        "what is ", "say "]
        guard let opening = openings.first(where: lowered.contains),
              let range = lowered.range(of: opening)
        else { return nil }

        let rest = String(input[range.upperBound...])
        guard let (code, before, after) = Tongues.firstNamed(in: rest) else { return nil }

        // Either side of the language, because both word orders are natural:
        // "say good morning **in french**" and "translate **into hindi** where
        // is the station". Before wins when both have content, since that is the
        // commoner phrasing and the one that reads as a quotation.
        let phrase = clean(before) ?? clean(after)

        // Nothing on either side — "translate into French" is a request with no
        // object, which is a request to enter the *mode*, handled by the caller.
        guard let phrase else { return nil }

        return .translate(phrase: phrase, code: code)
    }

    /// A candidate phrase with its wrapper stripped, or nil if nothing is left.
    private static func clean(_ raw: String) -> String? {
        var phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // The preposition that introduced the language, on whichever side it
        // ended up: "good morning **in**" before, or "**into** hindi" leaving
        // nothing meaningful after.
        for word in ["in", "into", "to", "for"] {
            if phrase.lowercased() == word {
                return nil
            }
            if phrase.lowercased().hasSuffix(" " + word) {
                phrase = String(phrase.dropLast(word.count + 1))
                break
            }
            if phrase.lowercased().hasPrefix(word + " ") {
                phrase = String(phrase.dropFirst(word.count + 1))
                break
            }
        }

        phrase = phrase.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ,"))
        return phrase.isEmpty ? nil : phrase
    }

    // MARK: - Calendar writes

    /// A request to *add* something, as opposed to read the day back.
    ///
    /// The needles all carry a verb of placement — "put ‹x› in my calendar",
    /// "schedule ‹x›", "book ‹x›". A bare "calendar" stays a read, which is what
    /// it has always been.
    private static func eventRequest(in text: String, original: String) -> Intent? {
        let openings = ["put ", "add ", "schedule ", "book ", "set up ", "create "]
        let targets = ["calendar", "meeting", "appointment", "event"]

        guard openings.contains(where: text.hasPrefix) || contains(text, ["schedule ", "book "]),
              contains(text, targets) || contains(text, ["at ", " on ", " tomorrow", " today"])
        else { return nil }

        // Reading, not writing: "what's on my calendar" opens with "what".
        guard !contains(text, ["what", "when is", "when's", "do i have", "am i free"]) else {
            return nil
        }

        return .event(title: eventTitle(from: original), when: original)
    }

    /// Strips the placement wrapper and the calendar words, so "put lunch with
    /// Priya in my calendar at 1pm" becomes "lunch with Priya".
    private static func eventTitle(from input: String) -> String {
        var title = input.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["put ", "add ", "schedule ", "book ", "set up ", "create "] {
            if title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
                break
            }
        }
        for filler in [" in my calendar", " to my calendar", " on my calendar",
                       " in the calendar", " as an event", " a meeting for", " a meeting"] {
            if let found = title.range(of: filler, options: .caseInsensitive) {
                title.removeSubrange(found)
            }
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Contacts

    /// Who was asked about, and what about them.
    ///
    /// The name is whatever follows the possessive or the verb, taken verbatim —
    /// `ContactService` does the real matching against nicknames and relations,
    /// because that needs the address book and this does not have it.
    private static func contactRequest(in text: String, original: String) -> Intent? {
        if let name = name(in: original, after: ["call ", "ring ", "phone ", "dial "]) {
            return .contact(name: name, aspect: .number, callable: true)
        }

        let aspect: ContactService.Aspect?
        if contains(text, ["number", "phone number", "mobile", "cell"]) {
            aspect = .number
        } else if contains(text, ["email", "e-mail", "email address"]) {
            aspect = .email
        } else if contains(text, ["birthday", "born on"]) {
            aspect = .birthday
        } else {
            aspect = nil
        }

        guard let aspect, let name = possessiveName(in: original) else { return nil }
        return .contact(name: name, aspect: aspect, callable: false)
    }

    /// Words that follow a calling verb but are not a person.
    ///
    /// "Call me back", "call it off", "call her later" — the verb is there and
    /// nobody is being named. Routing those to Contacts puts a Call button in
    /// front of him for a phrase that had nothing to do with phoning anyone.
    private static let notPeople: Set<String> = [
        "me", "it", "them", "him", "her", "us", "you", "back", "off", "again",
        "later", "now", "please", "someone", "somebody", "a", "an", "the", "my"
    ]

    /// Who to ring: "call mom" → "mom", "phone Raj Malhotra" → "Raj Malhotra".
    private static func name(in input: String, after verbs: [String]) -> String? {
        let lowered = input.lowercased()

        for verb in verbs {
            guard let range = lowered.range(of: verb) else { continue }

            let words = input[range.upperBound...].split(separator: " ").map(String.init)
            guard let first = words.first, !notPeople.contains(first.lowercased()) else {
                return nil
            }

            // A second word only when it reads like the rest of a name. This is
            // what keeps "call mom later" from asking for someone called
            // "mom later", while still finding "Raj Malhotra".
            var name = first
            if words.count > 1,
               !notPeople.contains(words[1].lowercased()),
               words[1].first?.isUppercase == true {
                name += " " + words[1]
            }
            return name.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }
        return nil
    }

    /// The owner of a possessive: "what's Priya's number" → "Priya".
    private static func possessiveName(in input: String) -> String? {
        for token in input.split(separator: " ") {
            let word = String(token)
            guard let apostrophe = word.range(of: "'s") ?? word.range(of: "’s") else { continue }
            let owner = String(word[word.startIndex..<apostrophe.lowerBound])
            // Question words carry possessives too. "When's Priya's birthday"
            // has two, and taking the first asks Contacts for someone called
            // "when" — so the interrogatives are skipped and the loop moves on
            // to the name that follows.
            guard owner.count > 1, !["what", "who", "whose", "that", "it", "here",
                                     "there", "when", "where", "why", "how", "he",
                                     "she", "let", "today", "tomorrow"]
                .contains(owner.lowercased()) else { continue }
            return owner
        }
        return nil
    }

    // MARK: - Movement

    /// Steps and friends, with how far back he asked.
    ///
    /// Multi-word as ever: a bare "steps" catches "what are the next steps",
    /// and a bare "distance" catches half of everything.
    private static func motionRequest(in text: String) -> (aspect: MotionTool.Aspect, dayOffset: Int)? {
        let offset = text.contains("yesterday") ? -1 : 0

        if contains(text, ["how many steps", "step count", "my steps", "steps today",
                           "steps have i", "steps did i"]) {
            return (.steps, offset)
        }
        if contains(text, ["how far have i walked", "how far did i walk", "how far i walked",
                           "walking distance", "how much have i walked"]) {
            return (.distance, offset)
        }
        if contains(text, ["how many flights", "flights of stairs", "stairs have i",
                           "stairs did i", "floors climbed"]) {
            return (.flights, offset)
        }
        return nil
    }

    /// Strips the request wrapper so the reminder reads as the task itself:
    /// "remind me to call mom at 6pm" becomes "call mom at 6pm".
    ///
    /// The trailing time is deliberately left in. `ReminderService.stage`
    /// passes the whole utterance to `CalendarTool.firstDate(in:)` for the due
    /// date, so parsing the time out here would be duplicated work — and a
    /// slightly long title is a far better failure than a lost due date.
    private static func reminderTitle(from input: String) -> String {
        var title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["remind me to ", "remind me that ", "remind me ", "set a reminder to ", "set a reminder "] {
            if title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
                break
            }
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs the tool a routed turn asked for and writes the sentence.
///
/// Shared by `FridayEngine` and `AskFridayIntent`. The intent cannot go through
/// the engine: the engine owns `AVAudioEngine` and the audio session, and an
/// App Intent answering Siri must never touch either.
///
/// The model never sees these strings. It echoed `TimeTool`'s output word for
/// word on device, and a 3B model paraphrasing a number can quietly change it —
/// the worst failure an assistant has. Composing here means the value is always
/// right and "boss" is always present.
@MainActor
enum Lookup {
    static func answer(
        for intent: Intent,
        reminders: ReminderService,
        events: EventService,
        contacts: ContactService
    ) async -> String {
        do {
            switch intent {
            case .time(let includeDate):
                return addressed(try await TimeTool().call(arguments: .init(includeDate: includeDate)))

            case .device(let aspect):
                return addressed(try await DeviceTool().call(arguments: .init(aspect: aspect)))

            case .calendar(let day):
                return addressed(try await CalendarTool().call(arguments: .init(day: day, nextOnly: false)))

            case .reminder(let title, let when):
                // Staging only — D-34. The write still needs the Add it button.
                reminders.stage(title: title, when: when)
                guard let pending = reminders.pending else {
                    return "I didn't catch what to remind you about, boss."
                }
                return "That's \(pending.title), \(pending.spokenWhen), boss. Say the word and I'll add it."

            case .event(let title, let when):
                // Staged only, exactly like a reminder (D-34). Nothing reaches
                // the calendar without the Add it button.
                guard events.stage(title: title, when: when), let pending = events.pending else {
                    return "When should I put that down for, boss?"
                }
                return "That's \(pending.title), \(pending.spokenWhen), boss. Say the word and I'll add it."

            case .contact(let name, let aspect, let callable):
                return await contacts.answer(for: name, aspect: aspect, offeringCall: callable)

            case .nextBirthday:
                return await contacts.nextBirthday()

            case .motion(let aspect, let dayOffset):
                return await MotionTool.answer(aspect: aspect, dayOffset: dayOffset)

            case .reckon(let sum):
                // Computed, never recalled. D-44 at its cleanest: a model asked
                // "what's 15% of 4,200" answers confidently and is under no
                // obligation to be right.
                return ReckonTool.answer(sum)

            case .clipboard:
                return ClipboardTool.answer()

            case .timer:
                // Handled by the engine, which owns the notifier. Only Siri
                // reaches this.
                return "I'll set that in the app, boss."

            case .startTranslating, .stopTranslating:
                // A mode is a thing you are *in*, and Siri has nowhere to be in
                // it — the answer would be spoken once and the mode would have
                // nowhere to live.
                return "Open FRIDAY for that one, boss. I'll keep translating there."

            case .translate:
                // Only Siri arrives here, for the same reason as `.scan` below:
                // `FridayEngine` owns the translator and the voice that can
                // pronounce the answer, and Siri would read French aloud in an
                // English accent.
                return "I'll do that in the app, boss — I can say it properly there."

            case .scan:
                // Only Siri arrives here. `FridayEngine` intercepts every `.scan`
                // before the lookup, because reading needs a picture on screen
                // and an App Intent has no way to put a picker up — the same
                // shape of limit as the reminder case above.
                return "I'd need to see it, boss. Open FRIDAY and show me."

            case .chat:
                return ""
            }
        } catch {
            return "Couldn't get that one, boss. Say the word and I'll try again."
        }
    }

    /// Tools return plain factual sentences; FRIDAY always addresses him.
    static func addressed(_ sentence: String) -> String {
        let text = sentence.trimmingCharacters(in: .whitespaces)
        guard !text.lowercased().contains("boss") else { return text }
        return text.hasSuffix(".") ? String(text.dropLast()) + ", boss." : text + ", boss."
    }
}
