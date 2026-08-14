import SwiftUI

/// Everything FRIDAY can do, with the words that do it.
///
/// Routing is keyword-based (D-43), which means a capability exists exactly as
/// far as someone knows how to ask for it. Sixteen of them had accumulated
/// behind phrases nobody had been told. This is the manual — and it shows the
/// **phrasing**, not just the feature, because the phrasing is the interface.
struct CapabilitiesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Capability: Identifiable {
        let id = UUID()
        let icon: String
        let name: String
        let phrase: String
    }

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let items: [Capability]
    }

    private let groups: [Group] = [
        Group(title: "Your day", items: [
            .init(icon: "clock", name: "Time and date", phrase: "What time is it"),
            .init(icon: "calendar", name: "Your calendar", phrase: "What's on today"),
            .init(icon: "calendar.badge.plus", name: "Add an event", phrase: "Put lunch in my calendar at 1pm"),
            .init(icon: "checklist", name: "Reminders", phrase: "Remind me to call mom at 6"),
            .init(icon: "figure.walk", name: "Steps and distance", phrase: "How many steps have I done")
        ]),
        Group(title: "People", items: [
            .init(icon: "phone", name: "Call someone", phrase: "Call mom"),
            .init(icon: "person.text.rectangle", name: "Look someone up", phrase: "What's Priya's number"),
            .init(icon: "gift", name: "Birthdays", phrase: "Whose birthday is next")
        ]),
        Group(title: "Reading things", items: [
            .init(icon: "doc.viewfinder", name: "A page in front of you", phrase: "Read this"),
            .init(icon: "photo", name: "Something in your photos", phrase: "Read this screenshot"),
            .init(icon: "folder", name: "A PDF", phrase: "Read this PDF"),
            .init(icon: "qrcode.viewfinder", name: "A QR code or barcode", phrase: "What's this QR code"),
            .init(icon: "receipt", name: "A receipt or boarding pass", phrase: "Read this — she spots them herself")
        ]),
        Group(title: "Languages", items: [
            .init(icon: "character.bubble", name: "Translate", phrase: "How do you say good morning in French"),
            .init(icon: "text.bubble", name: "Hindi", phrase: "अभी क्या समय है — type it, she answers in Hindi")
        ]),
        Group(title: "This phone", items: [
            .init(icon: "battery.75", name: "Battery, storage, signal", phrase: "How's my battery")
        ])
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("FRIDAY listens for how you'd actually say it. If a phrase doesn't land, she'll just answer as herself rather than guess.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            LabeledContent {
                                EmptyView()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                    Text("“\(item.phrase)”")
                                        .font(.system(size: 13, design: .rounded))
                                        .foregroundStyle(FridayTheme.amber)
                                        // Wrapping rather than truncating, so a
                                        // long phrase stays readable at large
                                        // Dynamic Type instead of ending in an
                                        // ellipsis you cannot act on.
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .listRowSeparatorTint(.white.opacity(0.08))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(item.name). Say: \(item.phrase)")
                        }
                    }
                }

                Section {
                    Text("Hold the orb to speak, or just stop talking and she'll take the turn. Typing works just as well.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("What I can do")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    CapabilitiesSheet()
}
