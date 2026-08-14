import SwiftUI
import UserNotifications

@main
struct FRIDAYApp: App {
    @State private var engine = FridayEngine()

    /// Kept alive for the lifetime of the app because
    /// `UNUserNotificationCenter.delegate` is a **weak** reference — a responder
    /// created inline would be released immediately and Done and Snooze would
    /// silently do nothing.
    @State private var responder: NotificationResponder?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .preferredColorScheme(.dark)
                .task {
                    // Registering the category does *not* prompt — only
                    // `requestAuthorization` does, and that waits until the
                    // first reminder is actually confirmed. So this is safe to
                    // run at launch and the app still asks for nothing up front.
                    engine.notifier.registerActions()

                    let responder = NotificationResponder(notifier: engine.notifier)
                    self.responder = responder
                    UNUserNotificationCenter.current().delegate = responder
                }
        }
    }
}
