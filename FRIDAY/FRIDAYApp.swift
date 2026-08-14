import SwiftUI

@main
struct FRIDAYApp: App {
    @State private var engine = FridayEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .preferredColorScheme(.dark)
        }
    }
}
