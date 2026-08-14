import SwiftUI

/// What the share sheet shows.
///
/// The palette is repeated rather than shared, for the same reason as the
/// widget: `FridayTheme` lives in the app target and pulling it across would
/// drag the rest of the app's types with it, for four colours.
struct SharedTextView: View {
    @Bindable var model: ShareModel

    private let ground = Color(red: 0.043, green: 0.047, blue: 0.055)
    private let amber = Color(red: 1.000, green: 0.702, blue: 0.231)
    private let primary = Color(white: 0.965)
    private let secondary = Color(white: 0.640)

    var body: some View {
        NavigationStack {
            ZStack {
                ground.ignoresSafeArea()

                switch model.state {
                case .reading:
                    ProgressView()
                        .controlSize(.large)
                        .tint(amber)

                case .text(let text):
                    ScrollView {
                        Text(text)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }

                case .failed(let message):
                    Text(message)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(secondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                }
            }
            .navigationTitle("Read with FRIDAY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { model.onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .text(let text) = model.state {
                        // Copy rather than "send to FRIDAY" — with no App Group
                        // there is no route back into the app, and the clipboard
                        // is the one channel every app already shares. It also
                        // pairs with the app's own clipboard reading (D-66).
                        Button {
                            UIPasteboard.general.string = text
                            model.onDone()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
