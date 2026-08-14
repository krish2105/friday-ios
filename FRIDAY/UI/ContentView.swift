import SwiftUI

struct ContentView: View {
    @Environment(FridayEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var availability = AIAvailability()
    @State private var appeared = false
    @State private var pulsing = false
    @State private var typed = ""
    @State private var showSettings = false

    private var status: AIStatus { availability.status }
    private var isListening: Bool { engine.state == .listening }
    private var isThinking: Bool { engine.state == .thinking }

    /// Ambient accent follows FRIDAY's mood once she's said something.
    private var accent: Color {
        if isListening { return FridayTheme.amber }
        guard status.isReady else { return status.accent }
        return FridayTone(engine.conversation.last(where: \.isFriday)?.tone).color
    }

    var body: some View {
        ZStack {
            AmbientBackground(accent: accent)

            VStack(spacing: 0) {
                header
                    .reveal(appeared, delay: 0.05)

                if !status.isReady {
                    faultCard
                        .padding(.top, 16)
                        .reveal(appeared, delay: 0.12)
                }

                ConversationView(
                    turns: engine.conversation,
                    streamingText: engine.language.partialSpoken,
                    isThinking: isThinking
                )
                .frame(maxHeight: .infinity)
                .padding(.top, 12)
                .reveal(appeared, delay: 0.18)

                if case .preparing(let fraction) = engine.speech.assetState {
                    assetStrip(fraction: fraction)
                        .padding(.bottom, 10)
                } else if isListening {
                    liveTranscriptStrip
                        .padding(.bottom, 10)
                }

                reminderConfirm
                    .padding(.bottom, 12)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85),
                               value: engine.reminders.pending)

                errorBanner
                    .padding(.bottom, 12)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85),
                               value: engine.alert)

                // Grouped so the two floating controls share one sampling
                // region — glass cannot sample other glass on its own.
                GlassEffectContainer(spacing: 20) {
                    VStack(spacing: 16) {
                        debugInput
                            .reveal(appeared, delay: 0.26)

                        talkSection
                            .reveal(appeared, delay: 0.32)
                    }
                }

                footer
                    .padding(.top, 16)
                    .reveal(appeared, delay: 0.38)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
        }
        .onAppear {
            appeared = true
            pulsing = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { availability.refresh() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(output: engine.voice)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(FridayTheme.amber)
                .frame(width: 5, height: 5)

            Text("F.R.I.D.A.Y.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tracking(4.2)
                .foregroundStyle(FridayTheme.textPrimary.opacity(0.85))

            Spacer()

            if status.isReady {
                statusChip
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FridayTheme.textSecondary)
                    .frame(width: 34, height: 34)
                    .glassSurface(cornerRadius: 17)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var statusChip: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status.accent)
                .frame(width: 6, height: 6)
                .shadow(color: status.accent.opacity(0.9), radius: pulsing ? 6 : 2)
                .scaleEffect(pulsing ? 1.2 : 0.9)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.7).repeatForever(autoreverses: true),
                    value: pulsing
                )

            Text(status.badge)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(status.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(status.accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(status.accent.opacity(0.28), lineWidth: 1))
    }

    private var faultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status.statusMessage)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(FridayTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let fix = status.fixInstruction {
                Text(fix)
                    .font(.system(size: 13.5, weight: .regular, design: .rounded))
                    .foregroundStyle(FridayTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface(cornerRadius: 22)
    }

    // MARK: - Reminder confirmation
    //
    // The only path that writes to Reminders. The model stages; a real press
    // commits. Nothing a 3B model does on its own can create data here.

    @ViewBuilder
    private var reminderConfirm: some View {
        if let pending = engine.reminders.pending {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "checklist")
                        .font(.system(size: 13, weight: .semibold))
                    Text("CONFIRM REMINDER")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                }
                .foregroundStyle(FridayTheme.amber)

                Text(pending.title)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(FridayTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(pending.spokenWhen.prefix(1).uppercased() + pending.spokenWhen.dropFirst())
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(FridayTheme.textSecondary)

                HStack(spacing: 10) {
                    Button {
                        engine.cancelReminder()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(FridayTheme.textSecondary)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }

                    Button {
                        Task { await engine.confirmReminder() }
                    } label: {
                        Text("Add it")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(FridayTheme.ground)
                            .background(Capsule().fill(FridayTheme.amber))
                    }
                }
                .buttonStyle(.plain)
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
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Error banner
    //
    // The only route out of `.error`. Without it the state machine dead-ends
    // and the talk button stops responding for the rest of the session.

    @ViewBuilder
    private var errorBanner: some View {
        if let alert = engine.alert {
            Button {
                engine.dismissAlert()
            } label: {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FridayTheme.fault)

                    Text(alert)
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
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityHint("Tap to dismiss")
        }
    }

    // MARK: - Asset download
    //
    // The speech model is fetched by the system on first use. CLAUDE.md's trap
    // table calls this out: without a visible state, the first transcription
    // just silently fails.

    private func assetStrip(fraction: Double?) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(FridayTheme.downloading)

            Text(fraction.map { "Downloading speech model… \(Int($0 * 100))%" }
                 ?? "Downloading speech model…")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(FridayTheme.downloading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(FridayTheme.downloading.opacity(0.12)))
        .overlay(Capsule().strokeBorder(FridayTheme.downloading.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Live transcript

    private var liveTranscriptStrip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(FridayTheme.amber)
                .frame(width: 5, height: 5)

            Text(engine.liveTranscript.isEmpty ? "Listening…" : engine.liveTranscript)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(FridayTheme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }

    // MARK: - Text input
    //
    // Kept as a first-class way in alongside the mic: quiet rooms, testing the
    // language engine without speaking, and demoing where a mic is awkward.

    private var debugInput: some View {
        HStack(spacing: 10) {
            TextField("Type to FRIDAY…", text: $typed)
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
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassSurface(cornerRadius: 22)
    }

    private var canSend: Bool {
        !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    private func send() {
        guard canSend else { return }
        let text = typed
        typed = ""
        Task { await engine.submit(text) }
    }

    // MARK: - Talk

    private var talkSection: some View {
        VStack(spacing: 12) {
            TalkButton(
                state: engine.state,
                level: engine.speech.level,
                onPress: { Task { await engine.startListening() } },
                onRelease: { Task { await engine.stopListening() } }
            )

            Text(talkHint)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(FridayTheme.textSecondary)
        }
    }

    private var talkHint: String {
        switch engine.state {
        case .listening: "Release to finish"
        case .thinking: "Thinking…"
        case .speaking: "Press to interrupt"
        case .idle, .error: "Hold to talk"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 9) {
            Text("SYSTEM")
            Circle().frame(width: 2.5, height: 2.5)
            Text(engineStateLabel)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .tracking(1.6)
        .foregroundStyle(FridayTheme.textSecondary.opacity(0.7))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var engineStateLabel: String {
        switch engine.state {
        case .idle: "IDLE"
        case .listening: "LISTENING"
        case .thinking: "THINKING"
        case .speaking: "SPEAKING"
        case .error(let message): "ERROR — \(message.uppercased())"
        }
    }
}

// MARK: - Staggered entrance

private struct Reveal: ViewModifier {
    var shown: Bool
    var delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .animation(
                reduceMotion ? .none : .spring(response: 0.75, dampingFraction: 0.85).delay(delay),
                value: shown
            )
    }
}

private extension View {
    func reveal(_ shown: Bool, delay: Double) -> some View {
        modifier(Reveal(shown: shown, delay: delay))
    }
}

#Preview {
    ContentView()
        .environment(FridayEngine())
}
