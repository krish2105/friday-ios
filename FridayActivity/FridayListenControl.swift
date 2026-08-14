import AppIntents
import SwiftUI
import WidgetKit

/// Control Centre button that opens FRIDAY listening.
///
/// One of the three legitimate entry points, alongside push-to-talk and Siri.
/// iOS does not permit a persistent background wake-word listener for
/// third-party apps, and this project documents that constraint rather than
/// faking it with background audio modes.
///
/// It is also what makes the Live Activity worth having: starting a turn from
/// Control Centre means the app is not frontmost, which is the only situation
/// in which iOS renders an app's own Live Activity in the Dynamic Island.
struct FridayListenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.krishnamathur.friday.listen") {
            ControlWidgetButton(action: StartListeningIntent()) {
                Label("FRIDAY", systemImage: "waveform.circle.fill")
            }
        }
        .displayName("Talk to FRIDAY")
        .description("Open FRIDAY ready to listen.")
    }
}
