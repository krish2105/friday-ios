import SwiftUI

/// Something FRIDAY has prepared and is waiting on.
///
/// One type for all of them, because they are one idea: the model got as far as
/// it is allowed to, and a real press decides the rest (D-34). Modelling them
/// separately is what produced four sibling cards in `ContentView`, any two of
/// which could be on screen at once, squeezing the conversation between them.
enum PendingAction: Equatable {
    case reminder(title: String, detail: String)
    case event(title: String, detail: String)
    case call(name: String, number: String)
    case link(URL)
    /// A screenshot was just taken and FRIDAY is offering to read it.
    case readScreenshot
    /// A business card read off a page, waiting to be written to Contacts.
    case saveContact(name: String, detail: String)
    case error(String)
}

/// The single slot every staged action passes through.
///
/// The shape stays put and its **contents** change — which is what
/// `glassEffectID` exists for, and why switching from a staged reminder to a
/// staged call morphs rather than one card leaving and another arriving.
struct ActionSlot: View {
    var pending: PendingAction?
    var onCancel: () -> Void
    var onConfirm: () -> Void

    /// Shared by every card so the glass treats them as one element changing,
    /// not several appearing.
    @Namespace private var slot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            if let pending {
                card(for: pending)
                    .glassEffectID("action", in: slot)
            }
        }
        // 220ms: inside the 150–300ms band for a micro-interaction, and a
        // spring rather than a curve because the card is a physical object
        // arriving, not a value being interpolated.
        .animation(
            reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.86),
            value: pending
        )
    }

    @ViewBuilder
    private func card(for pending: PendingAction) -> some View {
        switch pending {
        case .reminder(let title, let detail):
            ConfirmCard(icon: "checklist", heading: "CONFIRM REMINDER",
                        title: title, detail: detail, confirmTitle: "Add it",
                        onCancel: onCancel, onConfirm: onConfirm)

        case .event(let title, let detail):
            ConfirmCard(icon: "calendar.badge.plus", heading: "CONFIRM EVENT",
                        title: title, detail: detail, confirmTitle: "Add it",
                        onCancel: onCancel, onConfirm: onConfirm)

        case .call(let name, let number):
            ConfirmCard(icon: "phone.fill", heading: "CONFIRM CALL",
                        title: name, detail: number, confirmTitle: "Call",
                        onCancel: onCancel, onConfirm: onConfirm)

        case .link(let url):
            ConfirmCard(icon: "qrcode.viewfinder", heading: "OPEN THIS LINK?",
                        title: url.host() ?? "Unknown site",
                        // The whole address. A QR code is untrusted input from
                        // the physical world, and being able to read where it
                        // actually goes is the only defence there is.
                        detail: url.absoluteString,
                        confirmTitle: "Open",
                        onCancel: onCancel, onConfirm: onConfirm)

        case .readScreenshot:
            ConfirmCard(icon: "camera.viewfinder", heading: "SCREENSHOT TAKEN",
                        title: "Want me to read that?",
                        detail: "I'll pull the text out of it.",
                        confirmTitle: "Read it",
                        onCancel: onCancel, onConfirm: onConfirm)

        case .saveContact(let name, let detail):
            ConfirmCard(icon: "person.crop.circle.badge.plus", heading: "SAVE CONTACT",
                        title: name, detail: detail, confirmTitle: "Save",
                        onCancel: onCancel, onConfirm: onConfirm)

        case .error(let message):
            ErrorCard(message: message, onDismiss: onCancel)
        }
    }
}

/// The shell behind every staged action.
///
/// Shared so a fifth one cannot drift into looking like a different app, and so
/// the amber treatment reads consistently as *prepared, awaiting your say-so*.
struct ConfirmCard: View {
    var icon: String
    var heading: String
    var title: String
    var detail: String
    var confirmTitle: String
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(heading)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(FridayTheme.amber)

            Text(title)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(FridayTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(FridayTheme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                CardButton(title: "Cancel", isPrimary: false, action: onCancel)
                CardButton(title: confirmTitle, isPrimary: true, action: onConfirm)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(FridayTheme.amber.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(FridayTheme.amber.opacity(0.34), lineWidth: 1)
        )
    }
}

/// A failure, and the only route out of `.error`.
///
/// Without it the state machine dead-ends and the talk button stops responding
/// for the rest of the session — which it did, for four sessions.
private struct ErrorCard: View {
    var message: String
    var onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FridayTheme.fault)

                Text(message)
                    .font(.system(size: 13.5, weight: .regular, design: .rounded))
                    .foregroundStyle(FridayTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FridayTheme.textSecondary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FridayTheme.fault.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(FridayTheme.fault.opacity(0.38), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Tap to dismiss")
    }
}

/// 44pt minimum, because a 9pt-padded capsule is not a touch target.
private struct CardButton: View {
    var title: String
    var isPrimary: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: isPrimary ? .semibold : .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(isPrimary ? FridayTheme.ground : FridayTheme.textSecondary)
                .background(
                    Capsule().fill(isPrimary ? FridayTheme.amber : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }
}
