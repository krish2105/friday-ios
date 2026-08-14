import SwiftUI

/// Typing, and the way in to everything that isn't typing.
///
/// The action row exists because the app grew sixteen capabilities and kept
/// three visible controls. "Read this", "call mom" and "how do you say X in
/// French" all worked and none of them were *discoverable* — you had to already
/// know the phrase. A keyboard-first assistant with no visible verbs is a
/// command line wearing a nice coat.
struct InputBar: View {
    @Binding var text: String
    var isThinking: Bool
    var onSend: () -> Void
    var onAction: (Action) -> Void

    /// What the row offers. Deliberately four — the things you cannot express
    /// by typing, plus the one whose phrasing is worth teaching.
    enum Action: String, CaseIterable, Identifiable {
        case camera, code, files, translate

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .camera: "doc.viewfinder"
            case .code: "qrcode.viewfinder"
            case .files: "folder"
            case .translate: "character.bubble"
            }
        }

        var label: String {
            switch self {
            case .camera: "Scan a page"
            case .code: "Scan a code"
            case .files: "Read a PDF"
            case .translate: "Translate"
            }
        }
    }

    @State private var isExpanded = false
    @Namespace private var row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    var body: some View {
        VStack(spacing: 10) {
            // The row sits above the field rather than replacing it, so nothing
            // he has typed is ever hidden by opening it.
            if isExpanded {
                actionRow
                    .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
            }

            field
        }
        .animation(
            // 220ms in, and exit is left to the transition — `exit-faster-than-
            // enter` is handled by the scale anchor collapsing toward the button
            // it came from.
            reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.84),
            value: isExpanded
        )
    }

    // MARK: - The row

    private var actionRow: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Action.allCases) { action in
                    Button {
                        isExpanded = false
                        onAction(action)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: action.icon)
                                .font(.system(size: 17, weight: .medium))
                            Text(action.label)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(FridayTheme.textPrimary)
                        // 56pt, comfortably past the 44pt floor, and equal
                        // widths so no verb reads as more important than another.
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .glassSurface(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                    .glassEffectID(action.rawValue, in: row)
                    .accessibilityLabel(action.label)
                }
            }
        }
    }

    // MARK: - The field

    private var field: some View {
        HStack(spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "xmark" : "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isExpanded ? FridayTheme.amber : FridayTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide actions" : "Show what FRIDAY can do")

            TextField("Type to FRIDAY…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(FridayTheme.textPrimary)
                .tint(FridayTheme.amber)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(isThinking)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(canSend ? FridayTheme.amber : FridayTheme.textSecondary.opacity(0.35))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassSurface(cornerRadius: 26)
    }

    private func send() {
        guard canSend else { return }
        // Collapsing on send keeps the row from sitting open behind a reply.
        isExpanded = false
        onSend()
    }
}
