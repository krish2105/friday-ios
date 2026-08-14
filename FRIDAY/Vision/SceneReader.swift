import Foundation
import Vision

/// What's in the picture, when there are no words in it.
///
/// Until now, pointing the camera at anything textless got one line: *"There's
/// no text in that one."* Technically true and completely useless — it is the
/// answer a scanner gives, not the answer an assistant gives. Photograph a dog
/// and being told the dog contains no text is a small insult.
///
/// `ClassifyImageRequest` is free, on-device and needs no entitlement, and its
/// vocabulary is **1,303 identifiers** — enumerated on 2026-08-15, not taken
/// from documentation — including `dog`, `cat`, `food`, `people`, `car`,
/// `flower`, `bird`, `book`, `phone` and every room in a house.
///
/// **It is a classifier, not a describer.** It returns labels with confidences,
/// so FRIDAY says "a dog, and some grass" and never "a golden retriever playing
/// in your garden". The sentence is composed in Swift from the labels (D-44);
/// handing them to a 3B model to make prose out of is exactly how "dog 0.44"
/// becomes a confident story about your garden.
enum SceneReader {

    /// Below this a label is noise.
    ///
    /// Measured against real photographs on 2026-08-15: a clear scene put its
    /// top labels at 0.88–0.92 (`outdoor` 0.921, `sky` 0.915, `cloudy` 0.896 on
    /// a coastline), a rendered document at 0.713, and an abstract wallpaper
    /// with nothing in it topped out at 0.252 — which is the case this floor
    /// exists to reject.
    static let floor: Float = 0.35

    /// Labels that describe the *setting* rather than the subject.
    ///
    /// These fire together and constantly: a coastline returned `outdoor`,
    /// `sky`, `blue_sky` and `cloudy` within 0.03 of each other, which read
    /// aloud is four ways of saying one thing. They are kept only when nothing
    /// specific survives, so a photograph of genuinely nothing but sky still
    /// gets an answer.
    private static let setting: Set<String> = [
        "outdoor", "indoor", "sky", "blue_sky", "night_sky", "daytime",
        "nighttime", "land", "structure", "cloudy", "material", "surface",
        "background", "texture", "pattern", "art", "illustrations", "colour",
        "color", "light", "dark", "scene", "abstract"
    ]

    /// Parents suppressed when something more specific is present.
    ///
    /// `animal` beside `dog` adds nothing; `tree` beside `palm_tree` is worse
    /// than either alone.
    private static let generic: Set<String> = [
        "animal", "plant", "tree", "food", "people", "person", "vehicle",
        "furniture", "building", "room", "interior_room", "device", "tool",
        "document", "printed_page", "equipment", "container", "clothing"
    ]

    /// What's in the picture, and whether the lens wants a wipe.
    ///
    /// The Vision requests live here rather than in `FridayEngine`, which is how
    /// `TextScanner` is arranged too — the engine drives the conversation and
    /// does not know what a `ClassifyImageRequest` is.
    ///
    /// `Data` rather than `CGImage` for the same reason `TextScanner` takes it:
    /// a portrait iPhone photo is landscape pixels plus an EXIF orientation tag,
    /// and going via `UIImage(data:)?.cgImage` throws the tag away.
    static func read(_ image: Data) async -> (labels: [String], smudged: Bool)? {
        guard let seen = try? await ClassifyImageRequest().perform(on: image) else { return nil }

        // Best-effort and deliberately silent on failure — see
        // `smudgeThreshold`. A missing or broken smudge model reports ~0.0,
        // which is below the threshold, so it never speaks rather than speaking
        // wrongly.
        let smudge = try? await DetectLensSmudgeRequest().perform(on: image)

        return (labels(in: seen), (smudge?.confidence ?? 0) >= smudgeThreshold)
    }

    /// What the picture is of, best first, with the redundancy stripped out.
    static func labels(in observations: [ClassificationObservation]) -> [String] {
        let ranked = observations
            .filter { $0.confidence >= floor }
            .sorted { $0.confidence > $1.confidence }

        // Exact ties are the same label twice.
        //
        // Measured, and it is the sharpest signal in here. On a coastline
        // `rocks` and `structure` both came back at 0.663; on a rendered page
        // `document` and `printed_page` were both 0.713 — to three decimal
        // places. Genuinely distinct labels never land that way: `outdoor`
        // 0.921, `sky` 0.915 and `cloudy` 0.896 are all within 0.03 and all
        // different numbers. An exact tie means the classifier is reporting one
        // node under two names, so the first — Vision's own preferred ordering —
        // is kept and the rest dropped. Without this, FRIDAY said "a document
        // and a printed page".
        var seenConfidences: Set<Float> = []
        let strong = ranked
            .filter { seenConfidences.insert($0.confidence).inserted }
            .map(\.identifier)

        // A specific label beats the parent that contains it: with `palm_tree`
        // present, `tree` is dropped. Done on the identifier's own shape rather
        // than a hand-built hierarchy, because there are 1,303 of them and a
        // hand-built one would be wrong the first time Apple adds a label.
        let specific = strong.filter { candidate in
            !generic.contains(candidate)
                || !strong.contains { $0 != candidate && $0.contains(candidate) }
        }

        let subjects = specific.filter { !setting.contains($0) }

        // Setting words only when there is no subject at all — a photograph of
        // an empty sky should still get an answer rather than a shrug.
        let chosen = subjects.isEmpty ? specific : subjects
        return Array(chosen.prefix(3))
    }

    /// A label as something a person would say.
    static func spoken(_ identifier: String) -> String {
        names[identifier] ?? identifier.replacingOccurrences(of: "_", with: " ")
    }

    private static let names: [String: String] = [
        "printed_page": "a printed page",
        "document": "a document",
        "screenshot": "a screenshot",
        "blue_sky": "blue sky",
        "night_sky": "a night sky",
        "water_body": "water",
        "decorative_plant": "a houseplant",
        "computer_keyboard": "a keyboard",
        "computer_monitor": "a monitor",
        "adult_cat": "a cat",
        "flower_arrangement": "flowers",
        "interior_room": "a room",
        "living_room": "a living room",
        "dining_room": "a dining room",
        "kitchen_room": "a kitchen",
        "bathroom_room": "a bathroom"
    ]

    /// The line FRIDAY says about a picture with no words in it.
    ///
    /// Deliberately hedged. These are labels with confidences, not a
    /// description, and the register has to carry that without turning into a
    /// disclaimer — "looks like" does the whole job.
    static func sentence(for labels: [String], smudged: Bool = false) -> String {
        guard !labels.isEmpty else {
            return smudged
                ? "Nothing I can read, boss — and the lens looks smudged. Give it a wipe?"
                : "No words in that one, boss, and nothing I can put a name to."
        }

        let spokenLabels = labels.map(spoken)
        let listed: String
        switch spokenLabels.count {
        case 1: listed = spokenLabels[0]
        case 2: listed = "\(spokenLabels[0]) and \(spokenLabels[1])"
        default: listed = "\(spokenLabels[0]), \(spokenLabels[1]) and \(spokenLabels[2])"
        }

        let opening = "No words in that one, boss — looks like \(listed)."
        return smudged ? opening + " Your lens could do with a wipe, too." : opening
    }

    /// How smudged the lens has to look before it is worth mentioning.
    ///
    /// **Set high on purpose, and fail-safe.** `DetectLensSmudgeRequest` could
    /// not be verified on this Mac — `smudgenet-v1.E5.bundle` is absent from
    /// VisionCore here, so every probe returned ~0.00 with a console error, and
    /// the iPhone was unavailable at the time of writing. A threshold this far
    /// above zero means a model that is missing or broken on device stays
    /// **silent** rather than wrong: the failure mode is losing a nicety, not
    /// telling the boss to clean a lens that is already clean.
    static let smudgeThreshold: Float = 0.65
}
