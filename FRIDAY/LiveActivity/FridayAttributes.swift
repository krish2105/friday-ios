import ActivityKit

/// Shape of the Live Activity.
///
/// ⚠️ TARGET MEMBERSHIP — this file must belong to **both** the FRIDAY app
/// target and the widget extension target. The app writes the content state;
/// the extension renders it. If only one target has it, the extension won't
/// compile or the activity won't start.
struct FridayAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Listening", "Thinking", "Speaking" — already user-facing wording.
        var status: String
        /// Last thing FRIDAY said, trimmed for the expanded view.
        var snippet: String
    }

    /// Static for the life of the activity.
    var title: String
}
