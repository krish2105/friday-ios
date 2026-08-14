import AppIntents
import Foundation

/// Opens FRIDAY straight into listening. Driven by the Control Centre control.
///
/// ⚠️ TARGET MEMBERSHIP — this file must belong to **both** the app and the
/// widget extension. The extension needs the type to build the control; the app
/// needs it because `openAppWhenRun` makes `perform()` execute in the app's own
/// process once it is foregrounded.
///
/// That membership is why nothing here may touch `FridayEngine` or anything
/// else app-only: the extension has to compile this file too, and it cannot see
/// those types. Hence the plain `UserDefaults` handshake below rather than a
/// direct call or an `@Dependency`.
///
/// No App Group is involved, deliberately. `perform()` runs in the app process,
/// so `UserDefaults.standard` here *is* the app's own defaults — and App Groups
/// need a capability that would risk provisioning on a free account, the same
/// trap as WeatherKit in D-32.
struct StartListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to FRIDAY"
    static let description = IntentDescription("Open FRIDAY ready to listen.")

    /// The whole point of the control: push-to-talk without hunting for the app.
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: StartListeningIntent.pendingKey)
        return .result()
    }

    /// Read and cleared by `ContentView` when the scene becomes active.
    ///
    /// A flag rather than a notification because the app may still be launching
    /// when this runs, and a notification posted before the view exists is
    /// simply lost.
    static let pendingKey = "FridayPendingListen"
}
