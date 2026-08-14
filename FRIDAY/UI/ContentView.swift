import PhotosUI
import SwiftUI

struct ContentView: View {
    @Environment(FridayEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var availability = AIAvailability()
    @State private var appeared = false
    @State private var pulsing = false
    @State private var typed = ""
    @State private var showSettings = false
    @State private var showCapabilities = false
    @State private var picked: PhotosPickerItem?

    /// Lets the orb travel between the hero layout and the compact one.
    @Namespace private var orbSpace

    /// The hero owns the screen only while there is nothing to show. The
    /// moment a conversation exists it needs the room, so the orb shrinks and
    /// moves down rather than holding the middle of the display.
    private var isEmpty: Bool { engine.conversation.isEmpty }

    private var status: AIStatus { availability.status }
    private var isListening: Bool { engine.state == .listening }
    private var isThinking: Bool { engine.state == .thinking }

    /// Anything other than resting. Drives the ambient field's motion, which is
    /// held still at rest so Liquid Glass can cache its backdrop.
    private var isBusy: Bool {
        switch engine.state {
        case .listening, .thinking, .speaking: true
        case .idle, .error: false
        }
    }

    /// Ambient accent follows FRIDAY's mood once she's said something.
    private var accent: Color {
        if isListening { return FridayTheme.amber }
        guard status.isReady else { return status.accent }
        return FridayTone(engine.conversation.last(where: \.isFriday)?.tone).color
    }

    var body: some View {
        // The picker's presentation lives on the engine, because the turn that
        // raises it is routed there. `@Environment` hands back a plain value, so
        // this is the documented way to get a Binding out of one.
        @Bindable var engine = engine

        ZStack {
            VStack(spacing: 0) {
                StatusHeader(
                    status: status,
                    onSettings: { showSettings = true },
                    onCapabilities: { showCapabilities = true }
                )
                .reveal(appeared, delay: 0.05)

                if !status.isReady {
                    FaultCard(status: status)
                        .padding(.top, 16)
                        .reveal(appeared, delay: 0.12)
                }

                if isEmpty {
                    HeroPanel(
                        state: engine.state,
                        level: engine.speech.level,
                        namespace: orbSpace,
                        onPress: { Task { await engine.startListening() } },
                        onRelease: { Task { await engine.stopListening() } },
                        onSuggestion: { phrase in Task { await engine.submit(phrase) } }
                    )
                    .frame(maxHeight: .infinity)
                    .reveal(appeared, delay: 0.18)
                } else {
                    ConversationView(
                        turns: engine.conversation,
                        streamingText: engine.streamsVisibly ? engine.language.partialSpoken : "",
                        isThinking: isThinking
                    )
                    .frame(maxHeight: .infinity)
                    .padding(.top, 12)
                    .reveal(appeared, delay: 0.18)
                }

                StatusStrip(
                    assetState: engine.speech.assetState,
                    isListening: isListening,
                    liveTranscript: engine.liveTranscript
                )
                .padding(.bottom, 10)

                // One slot. Four services can each stage something, and as four
                // sibling cards any two could be on screen at once, squeezing
                // the conversation between them.
                ActionSlot(
                    pending: engine.pendingAction,
                    onCancel: { Task { await engine.cancelPending() } },
                    onConfirm: confirmPending
                )
                .padding(.bottom, 12)

                // Grouped so the two floating controls share one sampling
                // region — glass cannot sample other glass on its own.
                GlassEffectContainer(spacing: 20) {
                    VStack(spacing: 16) {
                        InputBar(
                            text: $typed,
                            isThinking: isThinking,
                            translatingInto: engine.translatingInto.map(Tongues.name(for:)),
                            onStopTranslating: { engine.translatingInto = nil },
                            onSend: send,
                            onAction: perform
                        )
                        .reveal(appeared, delay: 0.26)

                        // Only once the hero has handed the orb back. Two orbs
                        // on screen would both claim the same matched geometry.
                        if !isEmpty {
                            talkSection
                                .reveal(appeared, delay: 0.32)
                        }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The ambient field is a BACKGROUND, not a ZStack sibling. As a sibling
        // it sized the stack: its blobs have fixed frames up to 470pt, a ZStack
        // sizes to its largest child, and measuring on device confirmed the
        // root container was 470pt wide on a 402pt screen — so the whole
        // interface was laid out 470pt wide and clipped ~34pt at each edge.
        //
        // `.background` is proposed the primary view's size and can never grow
        // it, so this cannot regress. Capping the blobs inside AmbientBackground
        // was not enough; the containment has to be here.
        .background { AmbientBackground(accent: accent, isAnimating: isBusy) }
        // The one animation this layout adds, and it fires exactly twice in a
        // conversation's life: when the first turn arrives and the orb travels
        // down, and if the transcript is ever emptied. Nothing here runs at rest.
        .animation(
            reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82),
            value: isEmpty
        )
        .onAppear {
            appeared = true
            pulsing = true
        }
        // iOS tells us a screenshot happened but never hands over the image, and
        // reaching into PhotoKit for "the most recent one" would need a photo
        // permission — so FRIDAY offers, and the picker he chooses from stays
        // out of process.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification
        )) { _ in
            engine.offerScreenshot()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            availability.refresh()

            // Launched from the Control Centre control. Checked here rather
            // than via a notification because the intent runs while the app is
            // still coming up, and a notification posted before this view
            // exists would simply be lost.
            if UserDefaults.standard.bool(forKey: StartListeningIntent.pendingKey) {
                UserDefaults.standard.set(false, forKey: StartListeningIntent.pendingKey)
                Task { await engine.startListening() }
            }
        }
        .sheet(isPresented: $showCapabilities) {
            CapabilitiesSheet()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(output: engine.voice,
                         notifier: engine.notifier,
                         speech: engine.speech,
                         translator: engine.translator,
                         language: engine.language)
        }
        // Out-of-process picking, so this needs no photo library permission and
        // no usage string — the app only ever receives the one image he chose.
        // That matters here: every capability this project has reached for has
        // cost provisioning on a free account (D-32, D-46, D-52). This one is
        // free.
        // Filtered to screenshots when the screenshot offer raised it, so he is
        // not hunting through a year of photos for the one he took four seconds
        // ago. Out-of-process either way, so still no photo permission.
        .photosPicker(isPresented: $engine.showPhotoPicker,
                      selection: $picked,
                      matching: engine.wantsScreenshotsOnly ? .screenshots : .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            // Cleared straight away so picking the same photo twice still
            // fires — `onChange` only sees a *different* value.
            picked = nil
            engine.clearPhotoFilter()
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await engine.scan(data.map { [$0] } ?? [])
            }
        }
        // Full screen rather than a sheet: the scanner needs the whole viewfinder
        // to find the page edges, and a half-height card would fight it.
        .fullScreenCover(isPresented: $engine.showCamera) {
            DocumentCamera { pages in
                engine.showCamera = false
                // Backing out is not a failure and earns no line. An empty array
                // from the *picker* does, which is why the check is here rather
                // than inside `scan`.
                guard !pages.isEmpty else { return }
                Task { await engine.scan(pages) }
            }
            .ignoresSafeArea()
        }
        // PDFs only. The picker hands back a security-scoped URL, which
        // `PDFReader` opens explicitly — no entitlement, and the app never sees
        // anything but the one file he chose.
        .fileImporter(isPresented: $engine.showFilePicker,
                      allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            Task { await engine.readFile(url) }
        }
        // Full screen, like the document camera: a viewfinder you are aiming at
        // something in the world needs the whole screen to aim with.
        .fullScreenCover(isPresented: $engine.showLiveScanner) {
            LiveScanner(
                onRecognise: { payload, isCode in
                    Task { await engine.liveRecognised(payload, isCode: isCode) }
                },
                onCancel: { engine.showLiveScanner = false }
            )
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                // The system scanner has no chrome of its own, so without this
                // there is no way out but the app switcher.
                Button {
                    engine.showLiveScanner = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.black.opacity(0.55)))
                }
                .padding(20)
            }
        }
    }

    // MARK: - Acting

    private func send() {
        let text = typed
        typed = ""
        Task { await engine.submit(text) }
    }

    /// A press on the action row.
    ///
    /// The first three raise exactly what `Router` raises — a button and a
    /// phrase are two routes to the same place, not two implementations of it.
    /// Translate instead **pre-fills the phrase**, because it is the one action
    /// whose wording is worth teaching: press it once and you know how to ask
    /// for it out loud from then on.
    private func perform(_ action: InputBar.Action) {
        switch action {
        case .camera: engine.showCamera = true
        case .code: engine.showLiveScanner = true
        case .files: engine.showFilePicker = true
        case .translate: typed = "How do you say "
        }
    }

    /// Confirming belongs to the engine, except opening a link — that is the
    /// environment's, and the engine has no business holding `openURL`.
    private func confirmPending() {
        if case .link(let url) = engine.pendingAction {
            openURL(url)
            engine.cancelLink()
            return
        }
        Task { await engine.confirmPending() }
    }

    // MARK: - Talk

    private var talkSection: some View {
        VStack(spacing: 12) {
            TalkButton(
                state: engine.state,
                level: engine.speech.level,
                namespace: orbSpace,
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
