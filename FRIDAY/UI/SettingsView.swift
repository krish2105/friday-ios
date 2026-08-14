import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var output: SpeechOutput
    @Bindable var notifier: FridayNotifier
    @Bindable var speech: SpeechInput
    var translator: Translator
    var language: LanguageEngine

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                listeningSection
                voiceSection
                deliverySection
                nudgeSection
                hindiSection
                contextSection
            }
            .task { await translator.refreshAvailability() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Listening

    private var listeningSection: some View {
        Section {
            Toggle("Stop when I stop talking", isOn: $speech.autoStop)
        } header: {
            Text("Listening")
        } footer: {
            if speech.autoStop {
                Text("FRIDAY ends the turn after about a second and a half of silence. Holding the orb still works, and letting go still ends the turn immediately.")
            } else {
                // Not a lesser mode — the analyser is built exactly as it was
                // before the detector existed, so this is the path Sessions 2–7
                // verified rather than a variant of it.
                Text("Hold the orb to talk, let go to send. Nothing listens for pauses.")
            }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            Picker("Voice", selection: $output.voiceIdentifier) {
                Text("Automatic").tag(String?.none)
                ForEach(output.availableVoices, id: \.identifier) { voice in
                    Text("\(voice.name) · \(SpeechOutput.qualityLabel(voice.quality))")
                        .tag(String?.some(voice.identifier))
                }
            }

            Button {
                Task { await output.speak("Standing by, boss.") }
            } label: {
                Label("Hear a sample", systemImage: "speaker.wave.2.fill")
            }
            .disabled(!output.speakReplies)
        } header: {
            Text("Voice")
        } footer: {
            if output.hasHighQualityVoice {
                Text("Premium and Enhanced voices sound markedly better than Standard.")
            } else {
                // Siri's voices are off-limits to third-party apps, and there's
                // no API to offer downloads in-app — pointing at Settings is
                // genuinely the best available.
                Text("This device only has Standard-quality voices. For a much better one, download a Premium or Enhanced English voice in Settings → Accessibility → Live Speech → Voices.")
            }
        }
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        Section {
            Toggle("Speak replies", isOn: $output.speakReplies)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Rate")
                    Spacer()
                    Text(rateLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: $output.rate,
                    in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate
                ) {
                    Text("Speech rate")
                } minimumValueLabel: {
                    Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "hare.fill").foregroundStyle(.secondary)
                }
            }

            // The system minimum is 0.0, which stalls speech entirely. Keeping
            // the full range for accessibility, so this is the way back.
            Button("Reset to default rate") {
                output.rate = SpeechOutput.composedRate
            }
            .disabled(output.rate == SpeechOutput.composedRate)
        } header: {
            Text("Delivery")
        } footer: {
            Text("FRIDAY speaks a little under the system default, which reads as composed rather than hurried.")
        }
    }

    // MARK: - Reminders

    private var nudgeSection: some View {
        Section {
            Toggle("FRIDAY reminds you", isOn: $notifier.nudgesHimself)
        } header: {
            Text("Reminders")
        } footer: {
            // Exactly one of them should speak up. Both is redundant, neither
            // loses the reminder, so the toggle picks which.
            if notifier.nudgesHimself {
                Text("FRIDAY delivers the reminder herself, in her own words, with Done and Snooze on the notification. It's still saved to Apple Reminders — just without a second alert.")
            } else {
                Text("Apple Reminders alerts you as usual, and FRIDAY stays quiet. The reminder is saved either way.")
            }
        }
    }

    // MARK: - Hindi
    //
    // Reported rather than offered, for the same reason as the Premium voices
    // above: there is no API to download a language pack from inside the app.
    // A session built with `installedSource:` returns `canRequestDownloads ==
    // false` and throws `notInstalled`, so pointing at Settings is genuinely the
    // best available.

    private var hindiSection: some View {
        Section {
            LabeledContent("Hindi") {
                switch translator.isDownloaded {
                case true: Text("Ready").foregroundStyle(.green)
                case false: Text("Not downloaded").foregroundStyle(.secondary)
                case nil: ProgressView().controlSize(.small)
                }
            }
        } header: {
            Text("Languages")
        } footer: {
            if translator.isDownloaded == false {
                Text("Type to FRIDAY in Hindi and she'll answer in Hindi. Download it first in Settings → Apps → Translate → Downloaded Languages.\n\nHindi can't be spoken to her — the on-device transcriber has no Hindi at all, so Hindi has to be typed.")
            } else {
                Text("Type to FRIDAY in Hindi and she'll answer in Hindi, out loud. Hindi can't be spoken to her — the on-device transcriber has no Hindi at all, so it has to be typed.")
            }
        }
    }

    // MARK: - Context
    //
    // Not a feature — an instrument. D-18's overflow recovery has never been
    // observed running, and open issue 5 says it must not be called working. The
    // reason it stayed unverified is that nobody could see how close a
    // conversation was to the limit, so the only way to reach it was to type
    // until something happened. This makes the budget a number you can watch.

    @ViewBuilder
    private var contextSection: some View {
        // Hidden entirely below iOS 26.4 rather than shown empty — a meter with
        // no reading is worse than no meter.
        if let size = language.contextSize {
            Section {
                LabeledContent("Conversation") {
                    if let used = language.contextUsed {
                        Text("\(used.formatted()) / \(size.formatted()) tokens")
                            .monospacedDigit()
                            .foregroundStyle(used > size * 3 / 4 ? .orange : .secondary)
                    } else {
                        Text("nothing yet").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Context")
            } footer: {
                Text("How much of the model's window this conversation is using. When it fills, FRIDAY starts a fresh session and carries the last exchange across.")
            }
        }
    }

    private var rateLabel: String {
        let normalized = output.rate / AVSpeechUtteranceDefaultSpeechRate
        return String(format: "%.2f×", normalized)
    }
}

#Preview {
    SettingsView(output: SpeechOutput(),
                 notifier: FridayNotifier(),
                 speech: SpeechInput(),
                 translator: Translator(),
                 language: LanguageEngine(reminders: ReminderService(notifier: FridayNotifier())))
}
