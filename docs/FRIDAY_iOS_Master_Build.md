# PROJECT: F.R.I.D.A.Y. — iOS Voice Assistant

**Target:** iPhone 16 Pro · iOS 26 · Xcode 26
**Owner:** Krishna Mathur
**Execution:** Claude Code (Xcode project + Swift 6)
**Status:** Master build document v1

---

## 0. The One Decision That Shapes Everything

You said you want **all four** of: ship fast, portfolio piece, App Store eventually, learn the stack deeply — with the Python backend on **your Mac's local network**.

Those conflict. An App Store app cannot depend on a Python server in your bedroom. Reviewers will reject it, and users can't reach your Mac.

**Resolution: build in two phases, not one app.**

| | Phase 1 — "FRIDAY Core" | Phase 2 — "FRIDAY Link" |
|---|---|---|
| Brain | On-device Apple Foundation Models (~3B) | Cloud/large LLM via your Python agent |
| Backend needed | **None** | Mac on LAN (LiveKit + FastMCP) |
| Works offline | Yes, fully | No |
| API cost | Zero | Whatever your LLM costs |
| App Store legal | Yes | No (personal build only) |
| Ships in | ~1 week | ~1 week more |
| Demo-able | On a plane, airplane mode | Only at your desk |

Phase 1 alone is the stronger portfolio artifact. "This runs entirely on my phone, no internet, no API key" beats "let me boot my Mac first" in every interview. Phase 2 is your personal power mode and the thing that makes it feel like actual FRIDAY.

Build Phase 1 completely. Ship it. Then bolt on Phase 2 behind a settings toggle.

---

## 1. What You're Actually Building

A native SwiftUI app where you hold a button (or say a trigger phrase), speak, and FRIDAY:

1. Transcribes your speech **on-device** in real time
2. Decides whether it needs a tool (time, weather, calendar, reminders, web)
3. Calls that tool as a typed Swift function
4. Answers in the FRIDAY persona — dry, calm, calls you "boss"
5. Speaks the answer back
6. Shows a Live Activity in the Dynamic Island while it's thinking

Phase 2 adds: "boss, what's happening in the world" → routes to your Mac → MCP tools → news + world monitor.

---

## 2. The iOS 26 Stack (and why each piece)

| Layer | Framework | Why this one |
|---|---|---|
| Speech → text | `SpeechAnalyzer` + `SpeechTranscriber` | iOS 26's replacement for `SFSpeechRecognizer`. Fully on-device, AsyncSequence-based, low latency streaming |
| Voice activity | `SpeechDetector` | Detects when you've stopped talking so you don't need to tap "done" |
| Reasoning | `FoundationModels` → `SystemLanguageModel` | Apple's on-device ~3B LLM. No API key, no network, free |
| Structured output | `@Generable` / `@Guide` macros | Forces the model to return typed Swift structs instead of messy JSON strings |
| Tool calling | `Tool` protocol | The on-device equivalent of your MCP tools. This is the key piece |
| Text → speech | `AVSpeechSynthesizer` | Built in. Use a Siri-quality voice |
| UI | SwiftUI + Swift 6 concurrency | `@Observable`, actors, async/await |
| Ambient UI | ActivityKit (Live Activities) | Dynamic Island "FRIDAY listening / thinking" state |
| System hooks | App Intents | "Hey Siri, ask FRIDAY..." |
| Phase 2 transport | LiveKit Swift SDK v2 | Joins the same room as your `agent_friday.py` |

**Hardware gate:** Foundation Models needs iPhone 15 Pro / A17 Pro or newer. iPhone 16 Pro (A18 Pro) is well inside that. `SpeechAnalyzer` is iOS 26+ only, no backward compatibility.

---

## 3. Architecture

```
┌─────────────────────────────────────────────────┐
│                 FRIDAYApp (SwiftUI)             │
├─────────────────────────────────────────────────┤
│  ConversationView  │  OrbView  │  SettingsView  │
├─────────────────────────────────────────────────┤
│              FridayEngine (@Observable actor)   │
│   state: .idle .listening .thinking .speaking   │
└──────┬──────────────┬──────────────┬────────────┘
       │              │              │
   ┌───▼────┐   ┌─────▼──────┐  ┌───▼──────────┐
   │ Speech │   │ Foundation │  │  Speech      │
   │ Input  │   │ Models     │  │  Output      │
   │(STT)   │   │ + Tools    │  │  (TTS)       │
   └────────┘   └─────┬──────┘  └──────────────┘
                      │
        ┌─────────────┼─────────────┐
        │             │             │
   ┌────▼───┐  ┌──────▼─────┐ ┌────▼──────────┐
   │ Local  │  │  System    │ │ RemoteBridge  │
   │ Tools  │  │  Tools     │ │ (Phase 2)     │
   │ time   │  │ calendar   │ │ → Mac/LiveKit │
   │ math   │  │ reminders  │ │ → FastMCP     │
   │ device │  │ weather    │ │               │
   └────────┘  └────────────┘ └───────────────┘
```

**State machine — the whole app is this:**

```
idle → (button held / wake phrase) → listening
listening → (SpeechDetector says silence) → thinking
thinking → (tool call needed?) → toolExecuting → thinking
thinking → (answer ready) → speaking
speaking → (done) → idle
any → (error) → idle + spoken error in persona
```

---

## 4. File Structure

```
FRIDAY/
├── FRIDAYApp.swift                 # @main, app lifecycle
├── Info.plist                      # privacy strings (BOTH mic + camera)
├── FRIDAY.entitlements
│
├── Core/
│   ├── FridayEngine.swift          # the state machine, @Observable
│   ├── FridayState.swift           # enum: idle/listening/thinking/speaking
│   └── FridayPersona.swift         # system prompt, ported from agent_friday.py
│
├── Speech/
│   ├── SpeechInput.swift           # SpeechAnalyzer + SpeechTranscriber wrapper
│   ├── SpeechOutput.swift          # AVSpeechSynthesizer wrapper
│   └── AudioSessionManager.swift   # AVAudioSession .playAndRecord / .voiceChat
│
├── Intelligence/
│   ├── LanguageEngine.swift        # SystemLanguageModel + LanguageModelSession
│   ├── Generables.swift            # @Generable response structs
│   └── Availability.swift          # graceful degradation if AI unavailable
│
├── Tools/
│   ├── FridayTool.swift            # shared protocol conformance helpers
│   ├── TimeTool.swift              # get_current_time
│   ├── DeviceTool.swift            # battery, storage, connectivity
│   ├── WeatherTool.swift           # WeatherKit
│   ├── CalendarTool.swift          # EventKit read
│   ├── ReminderTool.swift          # EventKit reminders write
│   └── RemoteBridgeTool.swift      # Phase 2 — routes to Mac
│
├── UI/
│   ├── ConversationView.swift      # transcript + orb
│   ├── OrbView.swift               # the FRIDAY visual, reacts to state
│   ├── WaveformView.swift          # live mic amplitude
│   └── SettingsView.swift          # voice, persona, Phase 2 toggle
│
├── LiveActivity/
│   ├── FridayAttributes.swift
│   └── FridayLiveActivity.swift    # Dynamic Island
│
├── Intents/
│   └── AskFridayIntent.swift       # App Intent → Siri
│
└── Remote/                          # Phase 2 only
    ├── LiveKitSession.swift
    └── TokenProvider.swift
```

---

## 5. Prerequisites Checklist

Run through this **before** giving Claude Code anything.

| # | Item | How to verify |
|---|---|---|
| 1 | macOS 26 (Tahoe or later) | `sw_vers` |
| 2 | Xcode 26 + iOS 26 SDK | Xcode → About |
| 3 | iPhone 16 Pro on iOS 26 | Settings → General → About |
| 4 | Apple Intelligence **enabled** | Settings → Apple Intelligence & Siri → toggle ON |
| 5 | Device paired for development | Xcode → Devices & Simulators |
| 6 | Apple Developer account | free = 7-day builds; $99/yr = permanent + App Store |
| 7 | Enough free storage on phone | Foundation Models + speech assets need room |

**Critical:** If Apple Intelligence is off, `SystemLanguageModel.default.availability` returns unavailable and every AI call fails. This is the #1 cause of "it doesn't work" on this stack.

---

## 6. Claude Code Session Plan

Do **not** give Claude Code the whole thing at once. Seven sessions, each with a verifiable exit condition. This is the karpathy-guidelines pattern: every step has a check.

| Session | Builds | Verify by |
|---|---|---|
| 1 | Xcode project skeleton + availability check | App launches, prints "Foundation Models: available" |
| 2 | Speech input (STT) | Speak → live transcript on screen |
| 3 | Language engine + persona | Type a question → FRIDAY-voiced text answer |
| 4 | Speech output (TTS) | Answer is spoken aloud in a Siri voice |
| 5 | Tools (time, device, weather, calendar) | "What's my battery, boss?" → correct real number |
| 6 | UI polish — orb, waveform, Live Activity | Dynamic Island shows state |
| 7 | App Intent + Siri | "Hey Siri, ask FRIDAY the time" works |
| 8 (opt) | Phase 2 LiveKit bridge | "World news" routes to Mac, returns headlines |

---

## 7. Master Prompt — Session 1 (Foundation)

Paste this into Claude Code as-is.

````
You are building a native iOS app called FRIDAY, targeting iOS 26 on iPhone 16 Pro,
written in Swift 6 with SwiftUI. This is Session 1 of 8. Build ONLY what is
specified here. Do not scaffold future sessions.

## Rules for this entire project
- Minimum code that solves the problem. No speculative abstractions.
- No features beyond what this session asks for.
- If something is ambiguous, stop and ask me. Do not guess silently.
- State assumptions explicitly before you write code.
- Every changed line must trace to a requirement below.
- Use Swift 6 strict concurrency. Use @Observable, not ObservableObject.
- Target iOS 26 minimum. Do not add availability fallbacks for iOS 18 or earlier.

## Session 1 goal
A running SwiftUI app that correctly detects and reports whether Apple's
on-device language model is usable on this device.

## Requirements
1. Create an Xcode project structure for an app named FRIDAY, bundle id
   com.krishnamathur.friday, deployment target iOS 26.0.
2. Info.plist must contain BOTH of these privacy strings (Apple requires the
   camera string even though we never use the camera, because LiveKit is
   coming in a later session):
   - NSMicrophoneUsageDescription: "FRIDAY listens for your voice commands."
   - NSCameraUsageDescription: "Reserved for future visual input features."
   - NSSpeechRecognitionUsageDescription: "FRIDAY transcribes your speech on-device."
3. Create Intelligence/Availability.swift containing an @Observable class
   `AIAvailability` that:
   - imports FoundationModels
   - checks SystemLanguageModel.default.availability
   - exposes an enum: .ready, .appleIntelligenceOff, .deviceNotEligible,
     .modelDownloading, .unknown(String)
   - maps every case of SystemLanguageModel.Availability.UnavailableReason
     to one of the above
   - exposes a human-readable `statusMessage: String` for each case
4. Create a single ContentView that displays the availability status in large
   text, colour-coded: green for ready, orange for downloading, red otherwise.
   When not ready, show a one-line fix instruction (e.g. "Enable Apple
   Intelligence in Settings").
5. Create Core/FridayState.swift with:
   enum FridayState { case idle, listening, thinking, speaking, error(String) }
6. Create Core/FridayEngine.swift as an @Observable class holding
   `var state: FridayState = .idle` and nothing else yet. Wire it into the
   app as an @State in FRIDAYApp and pass via .environment().

## Success criteria
- Project builds with zero warnings under Swift 6 strict concurrency.
- Running on a physical iPhone 16 Pro with Apple Intelligence ON shows green
  "Ready" status.
- Toggling Apple Intelligence OFF and relaunching shows the red state with the
  correct fix instruction.

## Do not
- Do not add speech recognition yet.
- Do not add any LLM prompting yet.
- Do not add LiveKit.
- Do not create placeholder files for future sessions.

Before writing code, list your assumptions and confirm the FoundationModels
availability API surface you are targeting. If you are unsure of the exact
enum case names in the iOS 26 SDK, say so and ask me to check the header
rather than inventing names.
````

**Why that last paragraph matters:** the exact `UnavailableReason` case names are the single most likely thing for Claude Code to hallucinate. Making it declare uncertainty up front saves you a debug cycle.

---

## 8. Master Prompt — Session 2 (Speech Input)

````
Session 2 of 8. The FRIDAY app from Session 1 builds and reports AI
availability. Now add on-device speech-to-text.

## Same rules as Session 1
Minimum code. No speculation. Ask when unsure. Swift 6 strict concurrency.

## Goal
Hold a button, speak, see your words appear live on screen. Release, get a
final transcript. All on-device, no network.

## Requirements
1. Create Speech/AudioSessionManager.swift:
   - configures AVAudioSession with category .playAndRecord, mode .voiceChat
   - activates/deactivates cleanly
   - handles interruption notifications (phone call comes in)
2. Create Speech/SpeechInput.swift using the iOS 26 Speech framework:
   - use SpeechAnalyzer with a SpeechTranscriber module
   - use SpeechDetector to detect end-of-speech
   - ensure required language assets are requested/downloaded before first use,
     and expose a `prepareAssets()` async method
   - expose `AsyncStream<String>` of partial transcripts
   - expose a final transcript on stop
   - request microphone + speech recognition permission with proper async/await
3. Extend FridayEngine:
   - `func startListening() async` → state = .listening, begins transcription
   - `func stopListening() async` → state = .idle, returns final transcript
   - `var liveTranscript: String` updated from the partial stream
4. Update ContentView: a large circular push-to-talk button. Press and hold =
   listening. Show liveTranscript below it, updating in real time. Show a
   simple mic amplitude indicator.

## Success criteria
- On a physical device, holding the button and saying "testing one two three"
  shows the words appearing as you speak, not after you finish.
- Releasing produces a stable final transcript.
- Turning on Airplane Mode does not break transcription.
- Answering a phone call mid-listen does not crash the app.

## Notes
- SpeechAnalyzer is iOS 26+ only. Do not add SFSpeechRecognizer fallbacks.
- Language models live in a system-wide asset catalog, not your app bundle.
  First run may need a download; handle that state visibly in the UI.
- Do not implement TTS, LLM, or tools in this session.
````

---

## 9. Master Prompt — Session 3 (Brain + Persona)

````
Session 3 of 8. Speech input works. Now add the on-device language model and
the FRIDAY persona.

## Goal
Send a transcript to Apple's on-device model and get back a FRIDAY-voiced reply
as typed, structured Swift data.

## Requirements
1. Create Core/FridayPersona.swift holding the system instructions as a
   Swift string. Content:

   You are F.R.I.D.A.Y. — Fully Responsive Intelligent Digital Assistant for
   You. You serve Krishna, whom you address as "boss".
   Tone: calm, composed, precise, occasionally dry. Warm when the moment calls
   for it. You brief, you inform, you move on. No rambling.
   Speak like a trusted aide who stayed awake while the boss slept.
   Rules:
   - Never say tool names, function names, or anything technical. Ever.
   - Before a slow operation, say something natural: "Give me a sec, boss."
   - Use natural spoken language: contractions, commas for pauses.
   - Use Iron Man register naturally: "boss", "affirmative", "on it",
     "standing by".
   - If something fails, report it calmly and offer to retry.
   - Keep replies under 3 sentences unless asked to elaborate. This is spoken
     aloud — long answers are painful to listen to.
   - Never break character to explain that you are an AI assistant.

2. Create Intelligence/Generables.swift with a @Generable struct:
   @Generable
   struct FridayReply {
       @Guide(description: "What FRIDAY says aloud. Under 3 sentences. Spoken register, not written.")
       let spoken: String
       @Guide(description: "One short phrase describing the mood: calm, alert, amused, concerned")
       let tone: String
   }

3. Create Intelligence/LanguageEngine.swift:
   - holds a LanguageModelSession created with the persona instructions
   - `func respond(to input: String) async throws -> FridayReply` using
     guided generation
   - support streaming partial responses via the framework's streaming API
   - maintain conversation history across turns within a session
   - implement a session reset when the context window fills, preserving the
     persona instructions
   - typed error handling: distinguish guardrail rejection, context overflow,
     and model unavailable, and return a FRIDAY-voiced fallback line for each
     (e.g. context overflow → "Losing the thread a bit, boss. Starting fresh.")

4. Wire into FridayEngine: after stopListening produces a transcript, set
   state = .thinking, call the engine, store the reply, set state = .idle.

5. ContentView: show the conversation as a scrolling transcript, user turns
   right-aligned, FRIDAY turns left-aligned.

## Success criteria
- Ask "what can you do" → get a short, in-character, spoken-register reply.
- Ask something it can't know ("what's the stock price right now") → it says so
  in character rather than hallucinating a number.
- Ten turns in a row do not crash or lose the persona.
- Reply is always under roughly 3 sentences.

## Notes
- The on-device model is ~3B parameters, tuned for utility not world knowledge.
  Do not expect deep factual recall — that is what tools are for in Session 5.
- Guided generation with @Generable is the point here. Do not parse raw strings.
````

---

## 10. Master Prompt — Session 4 (Voice Output)

````
Session 4 of 8. Add speech synthesis so FRIDAY talks back.

## Requirements
1. Create Speech/SpeechOutput.swift wrapping AVSpeechSynthesizer:
   - pick the highest-quality available voice; prefer enhanced/premium English
     voices; expose a way to list and choose voices
   - slightly slower than default rate for a composed feel
   - `func speak(_ text: String) async` that completes when speech finishes
   - `func stop()` for barge-in
2. AudioSessionManager must duck/deactivate correctly so the mic isn't hearing
   FRIDAY's own voice. Ensure the session switches cleanly between record and
   playback.
3. FridayEngine: after a reply arrives, state = .speaking, speak it, then
   state = .idle.
4. Implement barge-in: pressing the talk button while FRIDAY is speaking stops
   playback immediately and starts listening.
5. SettingsView: voice picker, speech rate slider, toggle for "speak replies".

## Success criteria
- Full loop works hands-free-ish: hold, speak, release, hear a spoken reply.
- FRIDAY's own voice never gets transcribed back into the next turn.
- Tapping to talk mid-sentence cuts her off cleanly.
````

---

## 11. Master Prompt — Session 5 (Tools) — the important one

````
Session 5 of 8. This is the session that makes FRIDAY useful instead of a
chatbot. Add tool calling using the Foundation Models Tool protocol.

## Concept
The Tool protocol is the on-device equivalent of MCP tools. The model decides
when to call them, we execute real Swift code, the result goes back into the
model's context, and the model phrases the answer in persona.

## Requirements
1. Create Tools/TimeTool.swift conforming to Tool:
   - name, description, @Generable Arguments struct
   - returns current date/time, formatted naturally, respecting user locale
     and timezone
2. Create Tools/DeviceTool.swift:
   - battery level and charging state (UIDevice)
   - available storage
   - network reachability type (wifi/cellular/none)
   - thermal state
3. Create Tools/WeatherTool.swift using WeatherKit:
   - current conditions and today's forecast for the user's location
   - requires CoreLocation permission (when-in-use) — request it properly
   - requires the WeatherKit capability + entitlement; tell me exactly what to
     enable in the Apple Developer portal
4. Create Tools/CalendarTool.swift using EventKit:
   - read-only: today's events, next event, events on a named day
   - request calendar access with the iOS 17+ full-access API
5. Create Tools/ReminderTool.swift using EventKit:
   - create a reminder with title and optional due date
   - this one WRITES, so it must confirm verbally before creating
6. Register all tools on the LanguageModelSession.
7. Every tool must return a FRIDAY-appropriate failure string on error, never
   throw raw errors into the model's context.

## Success criteria — test each of these verbally
- "What time is it, boss?" → correct local time, spoken naturally
- "How's my battery?" → correct real percentage
- "What's the weather?" → real current conditions for actual location
- "What's on my calendar today?" → real events
- "Remind me to call mom at 6pm" → confirms, then actually creates the reminder
- "What's the capital of Uzbekistan?" → answers WITHOUT calling any tool
- Deny calendar permission → FRIDAY reports it calmly in character, no crash

## Critical
The persona rule "never say tool names" must hold. If any reply contains
"TimeTool", "get_current_time", "function", or "I will now call" — that is a
failure. Test this explicitly.
````

---

## 12. Master Prompt — Session 6 (The FRIDAY Look)

````
Session 6 of 8. Visual identity + ambient presence.

## Requirements
1. Create UI/OrbView.swift — the FRIDAY visual. A circular reactive orb:
   - idle: slow ambient breathing pulse, dim
   - listening: expands, reacts to live mic amplitude
   - thinking: rotating/shifting internal motion
   - speaking: pulses in time with speech
   Implement with SwiftUI Canvas or a Metal shader. Keep it under 60fps budget
   and make sure it does not spike CPU when idle.
2. Colour direction: deep charcoal background, amber/gold accent (Stark
   palette), not blue. Avoid looking like a Siri clone.
3. Adopt iOS 26 Liquid Glass materials for panels and controls where
   appropriate — this app should look native to iOS 26, not like a 2023 app.
4. Create LiveActivity/ with ActivityKit:
   - Live Activity showing FRIDAY state
   - Dynamic Island compact view: small orb + state
   - Dynamic Island expanded: state + last reply snippet
5. Haptics: distinct feedback for listening start, reply received, error.

## Success criteria
- Idle CPU under 5% on device.
- Dynamic Island updates within ~200ms of state change.
- Looks intentional and designed, not like a default SwiftUI template.
````

---

## 13. Master Prompt — Session 7 (System Integration)

````
Session 7 of 8. Make FRIDAY reachable from outside the app.

## Requirements
1. Create Intents/AskFridayIntent.swift using App Intents:
   - an intent "Ask FRIDAY" taking a spoken string parameter
   - returns FRIDAY's reply as both spoken and displayed result
   - donate it so Siri and Shortcuts can discover it
2. Add AppShortcutsProvider with natural phrases:
   - "Ask FRIDAY", "Brief me, FRIDAY", "FRIDAY status"
3. Add a Control Center control (iOS 18+ Controls API) that launches straight
   into listening mode.
4. Add a Lock Screen widget showing last brief timestamp.

## Success criteria
- "Hey Siri, ask FRIDAY what time it is" works without opening the app.
- The shortcut appears in the Shortcuts app automatically.

## Honest constraint to respect
iOS does not permit a persistent always-on background wake-word listener for
third-party apps. Do not attempt to fake it with background audio modes — that
is an App Store rejection and a battery disaster. Push-to-talk, Siri, and the
Control Center control are the legitimate entry points. Note this limitation in
the README rather than working around it.
````

---

## 14. Phase 2 — Session 8 (LiveKit Bridge to Your Mac)

Only after Phase 1 ships. This is your personal power mode, **not** App Store material.

**What changes on the Mac side:** almost nothing. Your existing `server.py` (FastMCP on `:8000/sse`) and `agent_friday.py` keep running exactly as they do now. The iOS app becomes a second client joining the same LiveKit room the web Playground was joining.

**What you need to add:**

| Piece | Why |
|---|---|
| Token server | LiveKit join tokens must be signed server-side. Never ship API secrets in an iOS binary. Run a tiny FastAPI endpoint on your Mac. |
| LiveKit Swift SDK v2 | Note: **v2 has breaking changes from v1.** Claude Code must target v2 patterns. |
| Mac reachable on LAN | Static local IP or `.local` hostname. Firewall must allow the ports. |
| ATS exception | iOS blocks plaintext HTTP by default. Either use TLS or add a scoped `NSAppTransportSecurity` exception for your Mac's local address only. |

````
Session 8. Phase 2 — optional remote bridge. This is a personal-use feature
behind a settings toggle, explicitly NOT for App Store submission.

## Goal
When "Remote Brain" is enabled in Settings and the Mac is reachable, heavy
queries route to the Python LiveKit agent + FastMCP tools instead of the
on-device model. When it is off or unreachable, everything falls back to
on-device silently.

## Requirements
1. Add LiveKit Swift SDK v2 via SPM: https://github.com/livekit/components-swift
   Target v2 APIs specifically. v1 patterns will not compile.
2. Create Remote/TokenProvider.swift fetching a join token from my Mac's token
   server at a configurable host. Never embed API key or secret in the app.
3. Create Remote/LiveKitSession.swift:
   - connect to the room, publish mic, subscribe to agent audio
   - enable preConnectAudio so connection feels instant
   - expose connection state and surface it in the UI
4. Create Tools/RemoteBridgeTool.swift — a Foundation Models Tool that the
   on-device model can call for anything needing web/news/live data. It hands
   off to the LiveKit session.
5. Routing logic in FridayEngine:
   - remote disabled → always on-device
   - remote enabled + reachable → route web/news/world queries remotely,
     keep time/battery/calendar local (they're instant on-device)
   - remote enabled + unreachable → fall back on-device, FRIDAY says so in
     character: "Can't reach the workshop right now, boss. Running local."
6. SettingsView: Remote Brain toggle, Mac host field, connection test button
   with a clear pass/fail result.

## Success criteria
- Toggle off: works fully in Airplane Mode.
- Toggle on, Mac running: "What's happening in the world?" returns real
  headlines from the Python agent.
- Toggle on, Mac off: graceful in-character fallback within 3 seconds, no hang,
  no crash.

## Do not
- Do not embed LiveKit API secrets in the app.
- Do not make Phase 1 features depend on the Mac being up.
````

---

## 15. Known Traps (read before you start)

| Trap | Symptom | Fix |
|---|---|---|
| Apple Intelligence off | Every AI call fails silently | Session 1's availability check exists for exactly this |
| Simulator | Foundation Models unavailable/limited | Test on the physical iPhone 16 Pro, always |
| Mic hears TTS | FRIDAY transcribes herself, infinite loop | AudioSession must fully switch modes between record/playback |
| Both privacy strings | Crash on launch or rejection | Camera string required even unused, once LiveKit is added |
| LiveKit v1 vs v2 | Code won't compile | Explicitly pin and target v2 |
| Speech assets not downloaded | First transcription silently fails | Call `prepareAssets()` on first launch, show progress |
| Model hallucinating facts | Confidently wrong answers | The 3B model is for utility, not knowledge. Tools carry the facts |
| Tool names leaking into speech | "I will now call get_current_time" | Test this explicitly every session |
| Context overflow | Session dies after long conversation | Session 3's reset-preserving-persona logic |

---

## 16. Portfolio Framing

When this goes on `krishnamathur-ai.vercel.app` or into an interview, lead with the engineering decisions, not the Iron Man theme:

- **On-device inference**, zero API cost, works in airplane mode
- **Typed LLM output** via guided generation — not string parsing
- **Tool-calling architecture** that mirrors MCP, implemented natively in Swift
- **Graceful degradation** across four failure modes (AI off, ineligible device, permissions denied, remote unreachable)
- **Honest constraint handling** — documented why always-on wake word isn't possible on iOS rather than hacking around it

That last one is what separates a student project from an engineer's project. Interviewers notice.

---

## 17. Viva / Interview Q&A

**Q: Why on-device instead of just calling GPT or Claude?**
Latency, privacy, and cost. The whole loop stays local — no network round-trip, no API bill, no data leaving the device. The tradeoff is a ~3B model with limited world knowledge, which is why the architecture pushes facts into tools rather than relying on model recall.

**Q: What is guided generation and why does it matter?**
The `@Generable` macro lets you define a Swift struct and have the model's output conform to it directly, with `@Guide` annotations constraining individual fields. You get type-safe data instead of parsing JSON out of a text blob, and the framework handles validation and retry.

**Q: How does tool calling work here?**
Tools conform to a protocol with a name, a description, and a `@Generable` arguments struct. They're registered on the session. The model decides when a tool is needed, the framework invokes your Swift code, the result re-enters context, and the model phrases the final answer. Same conceptual shape as MCP, but in-process.

**Q: Why can't it always listen like the movie version?**
iOS doesn't allow third-party persistent background audio capture for wake-word detection. Background audio modes exist for media playback, not surveillance. Legitimate entry points are push-to-talk, Siri via App Intents, and Control Center. I documented the constraint instead of fighting it.

**Q: What breaks if the user has an iPhone 14?**
Foundation Models requires A17 Pro or newer, and `SpeechAnalyzer` requires iOS 26. On older hardware the availability check returns ineligible and the app explains why rather than crashing. A production version would fall back to a cloud model behind a user opt-in.

**Q: How would you scale this to the App Store?**
Phase 1 already qualifies — no backend, no keys, no data collection to disclose. Phase 2's Mac dependency would be replaced by a hosted inference endpoint with proper auth, and the routing logic already handles remote-unavailable, so that swap is isolated to one file.

---

## 18. Do This Next

1. Run the Section 5 prerequisites checklist. Confirm Apple Intelligence is ON.
2. Open Claude Code in an empty directory.
3. Paste the Session 1 prompt exactly as written.
4. When it asks about the availability API surface — and it should — let it ask. Don't let it guess.
5. Verify against Session 1's success criteria on the physical phone before moving to Session 2.

Do not skip ahead. Each session's success criteria is the thing that stops you debugging four layers at once.
