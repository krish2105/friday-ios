import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var output: SpeechOutput

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                voiceSection
                deliverySection
            }
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

    private var rateLabel: String {
        let normalized = output.rate / AVSpeechUtteranceDefaultSpeechRate
        return String(format: "%.2f×", normalized)
    }
}

#Preview {
    SettingsView(output: SpeechOutput())
}
