# CLAUDE.md — FRIDAY iOS

Project rules for Claude Code. Read this before every task in this repository.

---

## Project

Native iOS voice assistant in the F.R.I.D.A.Y. persona (Iron Man).

- **Target device:** iPhone 16 Pro (A18 Pro)
- **Target OS:** iOS 26.0 minimum — no backward compatibility
- **Language:** Swift 6, strict concurrency
- **UI:** SwiftUI only
- **Bundle ID:** `com.krishnamathur.friday`
- **Owner:** Krishna Mathur

The build is split into two phases:

- **Phase 1 — FRIDAY Core:** fully on-device. Apple Foundation Models + SpeechAnalyzer. No backend, no API keys, works in airplane mode. App Store legal.
- **Phase 2 — FRIDAY Link:** optional remote brain via LiveKit to a Python FastMCP agent on a local Mac. Personal use only, behind a settings toggle. **Never** a dependency of Phase 1.

Phase 1 must remain fully functional with Phase 2 code deleted.

---

## Working rules

These override default behaviour. Follow them on every task.

### 1. Think before coding
- State assumptions explicitly before writing code.
- If multiple interpretations exist, present them. Do not pick silently.
- If something is unclear, stop and ask. Do not guess.
- If a simpler approach exists, say so. Push back when warranted.

### 2. Simplicity first
- Minimum code that solves the stated problem.
- No features beyond what was asked.
- No abstractions for single-use code.
- No configurability that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

### 3. Surgical changes
- Touch only what the task requires.
- Do not "improve" adjacent code, comments, or formatting.
- Do not refactor working code.
- Match existing style even if you'd do it differently.
- If you notice unrelated dead code, mention it — do not delete it.
- Remove only the imports/variables your own changes orphaned.

### 4. Verifiable goals
Every task ends with a stated success criterion and a way to check it. For multi-step work, state the plan first:

```
1. [step] → verify: [check]
2. [step] → verify: [check]
```

---

## API uncertainty rule

**This is the most important rule in this file.**

iOS 26 frameworks (`FoundationModels`, `SpeechAnalyzer`, `SpeechTranscriber`, `SpeechDetector`) are newer than most training data. Exact enum cases, initialiser signatures, and property names are easy to hallucinate.

If you are not certain of an exact API surface:

- **Say so explicitly.** Name what you're unsure about.
- **Ask me to check the header or documentation.**
- **Do not invent plausible-looking names.**

A wrong guess costs a full debug cycle on a physical device. An honest "I'm not sure of the exact `UnavailableReason` cases — can you check?" costs thirty seconds.

Highest-risk surfaces:
- `SystemLanguageModel.Availability` and its `UnavailableReason` cases
- `SpeechAnalyzer` module attachment and lifecycle
- `SpeechTranscriber` preset and locale configuration
- `@Generable` / `@Guide` macro parameter forms
- `Tool` protocol conformance requirements
- LiveKit Swift SDK **v2** (v1 patterns will not compile — target v2 only)

---

## Architecture

```
FRIDAYApp
  └── FridayEngine (@Observable)   ← state machine, single source of truth
        ├── SpeechInput            ← SpeechAnalyzer + SpeechTranscriber (STT)
        ├── LanguageEngine         ← SystemLanguageModel + LanguageModelSession
        │     └── Tools            ← Tool protocol conformances
        └── SpeechOutput           ← AVSpeechSynthesizer (TTS)
```

State machine — the whole app is this:

```
idle → listening → thinking → (toolExecuting → thinking)* → speaking → idle
any state → error → idle
```

`FridayEngine` owns state. Views observe it. Views never call speech or model APIs directly.

---

## Directory layout

```
FRIDAY/
├── FRIDAYApp.swift
├── Core/           FridayEngine, FridayState, FridayPersona
├── Speech/         SpeechInput, SpeechOutput, AudioSessionManager
├── Intelligence/   LanguageEngine, Generables, Availability
├── Tools/          TimeTool, DeviceTool, WeatherTool, CalendarTool, ReminderTool
├── UI/             ConversationView, OrbView, WaveformView, SettingsView
├── LiveActivity/   FridayAttributes, FridayLiveActivity
├── Intents/        AskFridayIntent
└── Remote/         LiveKitSession, TokenProvider   ← Phase 2 only
```

Do not create files for sessions that haven't started. No placeholder stubs for future work.

---

## Persona contract

FRIDAY's voice is a hard requirement, not decoration.

- Addresses the user as **"boss"**
- Calm, composed, precise, occasionally dry
- Replies **under 3 sentences** unless asked to elaborate — this is spoken aloud
- Spoken register: contractions, commas for pauses, no stiff phrasing
- Iron Man vocabulary used naturally: "on it", "affirmative", "standing by"
- Reports failures calmly and offers to retry
- Never breaks character to explain it's an AI assistant

**Absolute rule:** FRIDAY never says a tool name, function name, or anything technical. If any output contains `TimeTool`, `get_current_time`, "function", "I will now call", or similar — that is a bug. Test for it in every session that touches tools.

---

## Testing

- **Physical device only.** Foundation Models is unavailable or limited in the Simulator. Never claim a feature works based on a Simulator run.
- Apple Intelligence must be **ON** in Settings, or every model call fails.
- Test these failure modes deliberately, not just the happy path:
  - Apple Intelligence toggled off
  - Microphone permission denied
  - Calendar permission denied
  - Airplane mode (Phase 1 must work fully)
  - Phone call arriving mid-transcription
  - Ten-plus conversation turns (context overflow)

---

## Hard constraints — do not work around these

- **No always-on wake word.** iOS does not permit persistent background audio capture for third-party wake-word detection. Do not attempt background audio modes to fake it — App Store rejection and battery drain. Legitimate entry points: push-to-talk, Siri via App Intents, Control Center control.
- **No secrets in the binary.** LiveKit API keys, tokens, and credentials never ship in the app. Phase 2 uses a token server.
- **Both privacy strings required.** `NSMicrophoneUsageDescription` and `NSCameraUsageDescription` must both be present, even though the camera is unused, because LiveKit requires it.
- **No cloud fallback without explicit opt-in.** Foundation Models stays on-device by default. Do not add silent network paths.

---

## Known traps

| Trap | Symptom | Guard |
|---|---|---|
| Apple Intelligence off | All AI calls fail silently | `Availability.swift` check at launch |
| Simulator testing | Model unavailable | Physical device only |
| Mic hears TTS | FRIDAY transcribes herself, loops | AudioSession must switch modes cleanly |
| Speech assets not downloaded | First transcription silently fails | `prepareAssets()` on first launch with visible progress |
| Context overflow | Session dies after long chat | Reset session, preserve persona instructions |
| Model hallucinating facts | Confidently wrong answers | 3B model is for utility, not knowledge — facts come from tools |
| LiveKit v1 patterns | Won't compile | Target v2 explicitly |

---

## Commit style

- One logical change per commit
- Present tense, lowercase: `add speech input with SpeechAnalyzer`
- Reference the session: `session 2: add speech input`
- Do not commit `.xcuserdata`, build artefacts, or `DerivedData`
