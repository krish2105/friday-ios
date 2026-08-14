<div align="center">

<img src="FRIDAY/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="120" alt="FRIDAY">

# F.R.I.D.A.Y.

**A voice assistant that runs entirely on your iPhone.**
No server. No API key. No network. No cost.

`Swift 6` · `iOS 26` · `Foundation Models` · `SpeechAnalyzer` · `SwiftUI`

</div>

---

Hold the orb and speak. FRIDAY transcribes on-device, works out whether the question needs
real data, calls actual Swift code, and answers aloud — in airplane mode, on a plane, with
the network stack switched off entirely.

```
speech  →  SpeechAnalyzer  →  Router  →  Tool          →  reply  →  AVSpeechSynthesizer
           on-device STT      Swift      Swift code        text      on-device TTS
                                  ↘
                                    Foundation Models    ← conversation only
                                    on-device ~3B
```

---

## Why this is interesting

Most "AI assistants" are a text field wrapped around someone else's API. This one has no
network code in it at all.

| | FRIDAY | Typical cloud assistant |
|---|---|---|
| Latency | No round-trip | Round-trip per turn |
| Running cost | £0 | Per-token, forever |
| Privacy | Audio never leaves the device | Audio uploaded |
| Offline | Fully functional | Dead |
| Works if the vendor dies | Yes | No |

The honest trade: the on-device model is ~3B parameters and tuned for utility, not world
knowledge. The architecture compensates by pushing facts into tools rather than trusting
recall — and by not letting the model make routing decisions at all.

---

## The architecture decision worth reading

**Swift decides which tool runs. The model only speaks.**

The original design followed Apple's `Tool` protocol — register tools, let the model choose.
On device, with five tools registered, the model answered *"what can you do"* with the battery
level, sent *"what time is it"* to the reminder tool, and staged a reminder titled
*"What time is it?"*. Three rounds of prompt tuning did not fix it. Tool selection is not
something a model this size does reliably.

So routing moved into `Core/Intent.swift`. Swift matches intent, calls the tool, and composes
the sentence. The model keeps the one job it is genuinely good at: phrasing a conversational
reply.

Three consequences:

1. **Mis-routing is impossible**, not merely less likely — a tool cannot fire on a turn that
   was not routed to it.
2. **Numbers cannot be paraphrased into different numbers.** Factual sentences are built in
   Swift, so a small model rewording "80%" into "about 85%" is structurally unreachable.
3. **The session registers no tools**, handing the persona and conversation the entire
   ~4,096-token budget four schemas used to share.

And the one nobody planned: **with Apple Intelligence switched off, "what time is it" still
works.** Only conversation degrades. Half the app stopped depending on the model at all.

> This deliberately deviates from the original spec, which had the model choosing. The
> reasoning, and the device evidence behind it, is in [`docs/PORTFOLIO.md`](docs/PORTFOLIO.md).

---

## What it does

| Capability | Notes |
|---|---|
| **Live transcription** | Words appear *as you speak*, not after you finish |
| **Conversation** | On-device ~3B model, FRIDAY persona, typed output via `@Generable` |
| **Spoken replies** | `AVSpeechSynthesizer`, with barge-in — press the orb to cut her off |
| **Time & date** | Locale and timezone aware |
| **Device** | Battery, storage, connectivity, thermal state |
| **Calendar** | Read today's or tomorrow's events |
| **Reminders** | Staged only — a real button press commits the write |
| **Document reading** | On-device OCR via Vision — *in progress* |

**Reminders never write on their own.** The model can only *stage* a reminder;
`EKEventStore.save` is reachable solely from the **Add it** button. A 3B model misjudging a
turn must never be able to put junk in someone's real Reminders.

---

## Getting to it

Three entry points. iOS does not permit a persistent background wake-word listener for
third-party apps — this app documents that constraint rather than faking it with background
audio modes.

- **Push-to-talk** — hold the orb
- **Siri** — *"Hey Siri, ask FRIDAY"*, then your question
- **Control Centre & Lock Screen** — both open FRIDAY already listening

> Siri cannot take the question in the same breath. App Intents permits only `AppEntity` and
> `AppEnum` parameters inside a spoken phrase, and an open question is neither. A canned
> `AppEnum` would buy the one-shot phrasing at the cost of only ever answering a fixed list.

---

## Measured, not claimed

| | |
|---|---|
| Idle CPU | **2%** (Release, iPhone 16 Pro) against a 5% budget |
| Memory | ~21 MB |
| Network calls | 0 |
| Build | 0 errors, 0 warnings under `SWIFT_STRICT_CONCURRENCY = complete` |
| Defects found on device | 16 — none catchable by the compiler |

Getting idle CPU from 8% to 2% meant discovering that **Liquid Glass re-samples anything
animating beneath it**. Three continuous animations ran on a screen where nothing was
happening. Details in [`docs/PORTFOLIO.md`](docs/PORTFOLIO.md).

---

## Verified on hardware

Every criterion was tested on a physical iPhone 16 Pro. Nothing here is claimed from a
Simulator run — Foundation Models does not work there.

Including the failure modes, several by deliberately breaking things:

- Apple Intelligence off · microphone denied · calendar denied · speech assets failing
- Airplane mode · phone call mid-transcription · ten-plus conversation turns
- A wedged turn — bounded by a 20-second deadline, because a stuck state made the app
  unusable until relaunch

---

## Requirements

- **iPhone 15 Pro or newer** — A17 Pro is the real Foundation Models gate
  *(verified only on iPhone 16 Pro)*
- **iOS 26.0+**
- **Apple Intelligence enabled** — the app reports clearly if it is not
- Xcode 26, macOS 26 to build

## Build

```bash
open FRIDAY.xcodeproj
```

Select your physical iPhone and run. **The Simulator will not work.**

If `xcode-select` points at the Command Line Tools, build from the terminal without sudo:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project FRIDAY.xcodeproj -scheme FRIDAY \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

---

## Known limitations

Each of these is a decision with a stated trade-off, not an oversight.

**No always-on wake word.** iOS does not allow third-party background audio capture for
wake-word detection. Push-to-talk, Siri and Control Centre are the legitimate entry points.

**Limited world knowledge.** ~3B parameters, tuned for summarisation and extraction rather
than recall. Anything factual goes through a tool, and she declines rather than inventing.

**Keyword routing has gaps.** Unanticipated phrasings fall through to conversation. That is
deliberate: predictable and wrong in obvious ways beats unpredictable and wrong in surprising
ways.

**Conversations are ephemeral.** Nothing is written to disk — audio never leaves the phone and
transcripts never touch storage.

**Voice quality needs a manual download.** Siri's voices are not available to third-party apps
through `AVSpeechSynthesizer` — an Apple restriction. The best obtainable are the Premium and
Enhanced system voices, installed from Settings → Accessibility → Live Speech → Voices.

**Free-account constraints.** WeatherKit, App Groups and HealthKit all require a paid
membership; adding those entitlements breaks provisioning outright. So `WeatherTool` is
written but unregistered, and the Lock Screen widget is a launcher rather than a display.
Builds also expire every 7 days.

---

## Documentation

| | |
|---|---|
| [`docs/PORTFOLIO.md`](docs/PORTFOLIO.md) | The engineering write-up — decisions, and the things that turned out to be wrong |
| [`docs/HANDOVER.md`](docs/HANDOVER.md) | Current state, decision log, and how to build, deploy and debug this |
| [`CLAUDE.md`](CLAUDE.md) | Project rules |

---

## Roadmap

- [x] On-device speech, reasoning, tools, voice
- [x] Live Activity, Dynamic Island, haptics
- [x] App Intents, Siri, Control Centre, Lock Screen widget
- [ ] Document reading — camera OCR and structured extraction
- [ ] Contacts, richer Shortcuts actions, Apple Watch companion
- [ ] Optional remote brain over LiveKit *(personal use, not App Store eligible)*

---

<div align="center">

**Krishna Mathur** · [krishnamathur-ai.vercel.app](https://krishnamathur-ai.vercel.app)

</div>
