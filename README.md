# FRIDAY

A native iOS voice assistant that runs entirely on-device. No API keys, no network, no cost.

Built for iPhone 16 Pro on iOS 26 using Apple's Foundation Models framework and the iOS 26 Speech stack.

---

## What it does

Hold to talk. FRIDAY transcribes on-device, decides whether she needs a tool, calls real Swift code, and answers aloud in persona — all without a network connection.

```
speech → SpeechAnalyzer → Foundation Models → Tool → reply → AVSpeechSynthesizer
         (on-device STT)   (on-device ~3B)    (Swift)         (on-device TTS)
```

---

## Why on-device

| | On-device (this build) | Cloud LLM |
|---|---|---|
| Latency | No network round-trip | Round-trip per turn |
| Cost | Zero | Per-token |
| Privacy | Audio never leaves the phone | Audio leaves the phone |
| Offline | Works in airplane mode | Doesn't work |
| Knowledge depth | Limited (~3B params) | Deep |

The tradeoff is real: the on-device model is tuned for utility, not world knowledge. The architecture compensates by pushing facts into tools rather than relying on model recall.

---

## Stack

| Layer | Framework |
|---|---|
| Speech to text | `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26) |
| Voice activity | `AVAudioEngine` RMS (see Known limitations) |
| Reasoning | `FoundationModels` → `SystemLanguageModel` |
| Structured output | `@Generable` / `@Guide` macros |
| Intent routing | Swift keyword matching (see Measured) |
| Text to speech | `AVSpeechSynthesizer` |
| UI | SwiftUI, Swift 6 strict concurrency |
| Ambient UI | ActivityKit (Dynamic Island) |
| System hooks | App Intents (Siri) |

---

## System integration

Three entry points. iOS does not permit a persistent background wake-word listener for
third-party apps, and this app documents that constraint rather than faking it with
background audio modes.

- **Push-to-talk** — hold the orb.
- **Siri / Shortcuts** — "Hey Siri, ask FRIDAY", then the question. The question cannot be
  part of the phrase: App Intents only allows `AppEntity` and `AppEnum` parameters in a
  spoken phrase, and an open question is neither.
- **Control Centre / Lock Screen** — both open FRIDAY straight into listening. The Lock
  Screen widget is a launcher rather than a display, because reading app data from a widget
  needs an App Group, which requires a paid developer account.

## Measured

- **Idle CPU 2%** in a Release build on iPhone 16 Pro, against a 5% budget. Getting there
  meant finding that Liquid Glass re-samples anything animating beneath it, so three
  continuous idle animations had to stop — including the orb's resting pulse.
- **Tool routing is done in Swift, not by the model.** The on-device ~3B model mis-routed
  badly enough to answer "what can you do" with the battery level, so intent matching moved
  into code and the model kept only conversational phrasing.

## Requirements

- iPhone 15 Pro or newer (Foundation Models needs A17 Pro+)
  - Verified only on iPhone 16 Pro. A17 Pro is the real hardware gate, so
    15 Pro and 15 Pro Max should work, but that is untested.
- iOS 26.0 or later
- **Apple Intelligence enabled** in Settings — the app will not function otherwise
- Xcode 26 with the iOS 26 SDK
- macOS 26 or later to build

---

## Build

```bash
git clone https://github.com/krish2105/friday-ios.git
cd friday-ios
open FRIDAY.xcodeproj
```

Select your physical iPhone as the run destination and build. **The Simulator will not work** — Foundation Models is unavailable there.

On first launch the app checks model availability and reports clearly if Apple Intelligence is disabled or the device is ineligible.

---

## Tools

| Tool | Capability |
|---|---|
| Time | Current date and time, locale-aware |
| Device | Battery, storage, connectivity, thermal state |
| ~~Weather~~ | Written, **not registered** — WeatherKit needs a paid account |
| Calendar | Read today's events, next event |
| Reminders | Staged only; a real button press commits the write |

**Swift decides when a tool is needed, not the model** — see Measured. Factual answers are composed in Swift so a number can never be paraphrased into a different one. Tool names never appear in spoken output.

---

## Architecture notes

`FridayEngine` is a single `@Observable` state machine and the only source of truth:

```
idle → listening → thinking → (toolExecuting → thinking)* → speaking → idle
```

Views observe engine state. Views never touch speech or model APIs directly.

---

## Known limitations

**No always-on wake word.** iOS does not permit third-party apps to run persistent background audio capture for wake-word detection. This is a platform constraint, not an implementation gap. Entry points are push-to-talk, Siri via App Intents, and a Control Center control.

**Limited world knowledge.** The on-device model is roughly 3B parameters and tuned for summarisation, classification, and extraction — not factual recall. Anything requiring current or specific facts goes through a tool.

**Device gated.** iPhone 14 and older cannot run Foundation Models. The app detects this and explains it rather than failing silently.

**No `SpeechDetector`.** Voice activity comes from `AVAudioEngine` RMS instead. `SpeechDetector` did not conform to `SpeechModule` when this was written — an Apple bug, since fixed — and push-to-talk governs the turn regardless.

**Voice quality depends on a manual download.** Siri's voices are not available to third-party apps through `AVSpeechSynthesizer` — an Apple restriction, not an implementation gap. The best obtainable are the Premium and Enhanced system voices, each a 100 MB+ download the user installs from Settings → Accessibility → Live Speech → Voices. There is no API to offer those downloads in-app, so FRIDAY picks the best voice already present and tells you where to find better ones. On a device with only Standard voices she sounds noticeably more synthetic.

---

## Phase 2 (optional, not shipped)

An optional remote-brain mode bridges to a Python LiveKit + FastMCP agent on a local Mac for queries needing web access and a larger model. It sits behind a settings toggle, falls back to on-device when unreachable, and is **not** required for any Phase 1 feature.

This mode is for personal use and is not App Store eligible, since it depends on a machine on the local network.

---

## Author

Krishna Mathur — [krishnamathur-ai.vercel.app](https://krishnamathur-ai.vercel.app)
