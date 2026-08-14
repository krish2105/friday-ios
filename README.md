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
| Voice activity | `SpeechDetector` |
| Reasoning | `FoundationModels` → `SystemLanguageModel` |
| Structured output | `@Generable` / `@Guide` macros |
| Tool calling | `Tool` protocol |
| Text to speech | `AVSpeechSynthesizer` |
| UI | SwiftUI, Swift 6 strict concurrency |
| Ambient UI | ActivityKit (Dynamic Island) |
| System hooks | App Intents (Siri) |

---

## Requirements

- iPhone 15 Pro or newer (Foundation Models needs A17 Pro+)
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
| Weather | Current conditions via WeatherKit |
| Calendar | Read today's events, next event |
| Reminders | Create reminders (confirms verbally first) |

The model decides when a tool is needed. Tool names never appear in spoken output.

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

**Voice quality depends on a manual download.** Siri's voices are not available to third-party apps through `AVSpeechSynthesizer` — an Apple restriction, not an implementation gap. The best obtainable are the Premium and Enhanced system voices, each a 100 MB+ download the user installs from Settings → Accessibility → Live Speech → Voices. There is no API to offer those downloads in-app, so FRIDAY picks the best voice already present and tells you where to find better ones. On a device with only Standard voices she sounds noticeably more synthetic.

---

## Phase 2 (optional, not shipped)

An optional remote-brain mode bridges to a Python LiveKit + FastMCP agent on a local Mac for queries needing web access and a larger model. It sits behind a settings toggle, falls back to on-device when unreachable, and is **not** required for any Phase 1 feature.

This mode is for personal use and is not App Store eligible, since it depends on a machine on the local network.

---

## Author

Krishna Mathur — [krishnamathur-ai.vercel.app](https://krishnamathur-ai.vercel.app)
