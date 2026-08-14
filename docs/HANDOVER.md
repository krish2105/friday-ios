# FRIDAY iOS — Handover to a Mac session

**Written:** 2026-08-13 · **Repo state:** `main` @ `5bd4f3d` · **Commits:** 14

This document hands the project from a cloud Claude Code session (Linux, **no Swift
toolchain, no Xcode, no device**) to a session running on a Mac with Xcode 26 and a
physical iPhone 16 Pro.

Read this in full before touching anything. `CLAUDE.md` in the repo root governs all
work and outranks this document where they disagree.

---

## 1. The single most important fact

**Nothing since Session 1 has ever been compiled.**

Sessions 2 through 6 — roughly 2,600 lines across 21 files — were written by a model
that could not build, run, or test them. They were validated only by structural checks
(project-file integrity, file/target consistency, grep-level contract checks) and by web
research into API surfaces.

The code is written carefully and every uncertain API call is isolated behind a marked
seam, but **treat all of it as unproven until the compiler says otherwise.** Expect real
errors. That is the expected outcome, not a sign something went wrong.

Session 1 *was* verified on a physical device by the owner, so the project file opens,
the app launches, and the FoundationModels availability API is confirmed correct.

---

## 2. Project identity

| | |
|---|---|
| App | FRIDAY — on-device voice assistant, F.R.I.D.A.Y. persona |
| Owner | Krishna Mathur |
| Bundle ID | `com.krishnamathur.friday` |
| Deployment target | iOS 26.0 (no backward compatibility) |
| Language | Swift 6, `SWIFT_STRICT_CONCURRENCY = complete` |
| UI | SwiftUI only |
| Test device | iPhone 16 Pro, physical only |
| Targets | **One** — the app. No widget extension yet. |

**Phase 1 (Sessions 1–7)** is fully on-device: Apple Foundation Models + SpeechAnalyzer.
No backend, no API keys, works in airplane mode, App Store legal.
**Phase 2 (Session 8)** is an optional LiveKit bridge to a Mac. Not started. Phase 1 must
remain fully functional with all Phase 2 code deleted.

### Environment prerequisites (owner-side, not code)

- **Apple Intelligence must be ON** in Settings, or every model call fails. This is the
  number-one cause of "it doesn't work" on this stack.
- **Physical device only.** Foundation Models is unavailable or limited in the Simulator.
  Never claim a feature works from a Simulator run.
- **Free Apple Developer account.** This matters — see decision D-32.
- **Voice quality** depends on the owner downloading a Premium or Enhanced English voice
  in Settings → Accessibility → Live Speech → Voices. Until then FRIDAY sounds robotic.

---

## 3. What is built

29 Swift files, 2,868 lines.

| Dir | Files | Contents |
|---|---|---|
| `FRIDAY/` | 1 | `FRIDAYApp.swift` — `@main`, injects `FridayEngine` via `.environment()` |
| `Core/` | 4 | `FridayEngine` (state machine, single source of truth), `FridayState`, `FridayPersona`, `ConversationTurn` |
| `Intelligence/` | 3 | `Availability` (AI readiness), `Generables` (`FridayReply`), `LanguageEngine` (session, streaming, overflow recovery, typed errors) |
| `Speech/` | 3 | `AudioSessionManager`, `SpeechInput` (SpeechAnalyzer + capture + level), `SpeechOutput` (AVSpeechSynthesizer) |
| `Tools/` | 6 | `FridayTool` (shared failure phrasing), `TimeTool`, `DeviceTool`, `WeatherTool`, `CalendarTool`, `ReminderTool` + `ReminderService` |
| `UI/` | 9 | `ContentView`, `ConversationView`, `OrbView`, `TalkButton`, `SettingsView`, `AmbientBackground`, `GlassSurface`, `FridayTheme`, `Haptics` |
| `LiveActivity/` | 3 | `FridayAttributes`, `LiveActivityController`, `FridayLiveActivity` |

`FRIDAY/Intents/` is empty (`.gitkeep` only) — that is Session 7.

### Per-session status

| Session | Built | Verified on device |
|---|---|---|
| 0 — bootstrap (docs, scaffolding) | ✅ | n/a |
| 1 — availability + app shell | ✅ | ✅ by owner |
| 2 — speech input (STT) | ✅ | ❌ |
| 3 — language engine + persona | ✅ | ❌ |
| 4 — speech output + barge-in | ✅ | ❌ |
| 5 — tool calling (5 tools) | ✅ | ❌ |
| 6 — orb, haptics, Live Activity | ⚠️ code done, **widget target missing** | ❌ |
| 7 — App Intents, Siri, Control Centre | ❌ not started | ❌ |
| 8 — Phase 2 LiveKit bridge | ❌ out of scope for now | ❌ |

### The state machine

```
idle → listening → thinking → speaking → idle
any state → error → idle
```

`FridayEngine` owns `state`. Views observe it and never call speech or model APIs
directly. A `didSet` on `state` drives the Live Activity from one place.

---

## 4. Your mission, in three gated phases

Work the phases in order. **Do not start a phase until the previous one is complete.**
Report back at each gate.

### Phase A — Get to a green build

**Nothing else until this passes.** No new features, no refactors, no Session 7.

1. Open the project, let Xcode resolve any settings prompts.
2. Build for a physical iPhone 16 Pro:
   ```
   xcodebuild -project FRIDAY.xcodeproj -scheme FRIDAY \
     -destination 'generic/platform=iOS' build
   ```
3. Fix compile errors. Start with §5 (API seams) and §6 (concurrency) — the errors are
   very likely to be there.
4. Then eliminate **all warnings**. The success criterion is zero warnings under Swift 6
   strict concurrency.
5. Create the **widget extension target** (see §7) and get it building too.

**Gate:** app + extension build clean, zero warnings. Commit. Report exactly which seams
were wrong and what the real API turned out to be — that information is valuable and
should go back into the seam comments.

### Phase B — Verify Sessions 1–6 on the device

Run every success criterion. Fix what fails.

**Session 1** — Apple Intelligence ON shows green "Ready"; toggling it OFF and relaunching
shows the red state with the correct fix instruction.

**Session 2** — Hold the orb, say "testing one two three": words appear *as you speak*, not
after. Release gives a stable final transcript. Airplane mode does not break it. A phone
call mid-listen does not crash (it should stop cleanly and return to idle).

**Session 3** — "What can you do" gives a short in-character reply. "What's the stock price
right now" says it can't know rather than inventing a number. Ten turns without crashing
or losing persona. Replies stay under ~3 sentences.

**Session 4** — Full loop: hold, speak, release, hear a spoken reply. FRIDAY's own voice is
never transcribed into the next turn. Pressing the orb mid-sentence cuts her off cleanly
and starts listening.

**Session 5** — Test each verbally:
- "What time is it, boss?" → correct local time
- "How's my battery?" → correct real percentage
- "What's on my calendar today?" → real events
- "Remind me to call mom at 6pm" → confirmation card appears; **Add it** actually creates it
- "What's the capital of Uzbekistan?" → answered **without** calling any tool
- Deny calendar permission → FRIDAY reports it calmly in character, no crash
- Weather will fail on a free account — it should say so in character, not crash

**Session 6** — Idle CPU under 5% (Instruments, app foregrounded and idle). Dynamic Island
updates within ~200ms of state change. Haptics distinct for listening start, reply, error.

**Critical persona check, every session:** if any spoken or displayed reply ever contains
`TimeTool`, `currentTime`, `deviceStatus`, "function", "I will now call" or similar — that
is a bug. The persona contract forbids FRIDAY ever saying a tool or function name.

**Gate:** every criterion above passes on the physical device, or is documented as failing
with a reason. Commit fixes. Report results honestly — a failing criterion reported is
worth far more than a passing one assumed.

### Phase C — Session 7

Only after A and B. Full spec in `docs/FRIDAY_iOS_Master_Build.md` §13. Summary:

1. `Intents/AskFridayIntent.swift` — App Intent taking a spoken string, returning FRIDAY's
   reply as both spoken and displayed result; donated so Siri and Shortcuts find it.
2. `AppShortcutsProvider` with phrases: "Ask FRIDAY", "Brief me, FRIDAY", "FRIDAY status".
3. A Control Centre control that launches straight into listening.
4. A Lock Screen widget showing the last brief timestamp.

**Success:** "Hey Siri, ask FRIDAY what time it is" works without opening the app; the
shortcut appears in the Shortcuts app automatically.

**Hard constraint — do not work around this:** iOS does not permit third-party persistent
background audio capture for wake-word detection. Do not attempt background audio modes to
fake an always-on wake word. Push-to-talk, Siri via App Intents, and the Control Centre
control are the only legitimate entry points.

---

## 5. Unverified API seams — check these first

Each is marked `⚠️ API SEAM` in code and isolates one call whose exact signature could not
be confirmed without an SDK. If Phase A produces errors, they are most likely here.

| # | File:line | What is unverified |
|---|---|---|
| S-1 | `Speech/SpeechInput.swift:97` | `AssetInventory.assetInstallationRequest(supporting:)`, `request.progress`, `downloadAndInstall()` |
| S-2 | `Speech/SpeechInput.swift:153` | `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` and the `AVAudioConverter` path |
| S-3 | `Speech/SpeechInput.swift:203` | `analyzer.finalizeAndFinishThroughEndOfInput()` — **name unconfirmed**, may be `finalizeAndFinish(through:)` |
| S-4 | `Intelligence/LanguageEngine.swift:54` | `LanguageModelSession(tools:)` with `@InstructionsBuilder` trailing closure |
| S-5 | `Intelligence/LanguageEngine.swift:158` | `GenerationError` case names — only `exceededContextWindowSize`, `guardrailViolation`, `assetsUnavailable` matched by name |

**Confirmed by research, believed correct but never compiled:**
`SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` with
`.volatileResults`; `result.text` as `AttributedString`; `Tool` protocol as
`name`/`description`/`@Generable Arguments`/`call(arguments:) async throws -> String`;
`respond`/`streamResponse` with `.content` and `T.PartiallyGenerated`;
`glassEffect(_:in:)` with `Glass.regular/.clear/.identity`, `.tint()`, `.interactive()`.

When you learn the truth about a seam, **update the comment** so the next session inherits
fact rather than caution.

---

## 6. Swift 6 concurrency escape hatches

These compiled nowhere. Under `SWIFT_STRICT_CONCURRENCY = complete` they are the most
likely source of errors after the seams. Do not delete them blindly — each solves a real
problem described in its comment.

| File:line | Construct | Why it exists |
|---|---|---|
| `Speech/SpeechInput.swift:232` | `nonisolated(unsafe) let converter` | `AVAudioConverter` touched only on the audio thread inside the tap |
| `Speech/SpeechInput.swift:71` | `withCheckedContinuation` | `SFSpeechRecognizer.requestAuthorization` bridge |
| `Speech/SpeechOutput.swift:8` | `@unchecked Sendable` NSObject | `AVSpeechSynthesizerDelegate` bridge, kept off the observable type |
| `Speech/SpeechOutput.swift:92` | `withCheckedContinuation` | `speak()` completes when playback ends |
| `Speech/AudioSessionManager.swift:83` | `MainActor.assumeIsolated` | `Notification` is not `Sendable`; only `UInt` raw values cross |
| `Tools/WeatherTool.swift:6` | `@unchecked Sendable` NSObject | `CLLocationManager` delegate → one-shot async |
| `Tools/WeatherTool.swift:11` | `withCheckedContinuation` | same |

The two delegate-to-continuation bridges (`SpeechOutput`, `WeatherTool`) are the same
shape. If one needs adjusting, the other almost certainly does too.

---

## 7. The widget extension target — create this

The Live Activity code is written but **there is no extension target**, so it compiles
nowhere. Create it:

1. **File → New → Target → Widget Extension.** Name it `FridayActivity`. **Tick "Include
   Live Activity".** Deployment target iOS 26.0.
2. **Target membership** — this is the part that goes wrong:
   - `FRIDAY/LiveActivity/FridayAttributes.swift` → **both** app and extension targets.
   - `FRIDAY/LiveActivity/FridayLiveActivity.swift` → **extension only**, never the app.
     It is currently a project reference with no build-phase membership, deliberately.
3. Reference `FridayLiveActivity()` from the extension's generated `WidgetBundle`.
4. **Verify `NSSupportsLiveActivities` is actually `YES`** on the app target's Info tab.
   It was set via `INFOPLIST_KEY_NSSupportsLiveActivities`, and it is **not certain that
   build setting is honoured for this key**. If the Live Activity never starts, this is the
   first thing to check.

---

## 8. Decision log — do not undo these

Every entry was a deliberate choice made with the owner. Reversing one reintroduces a
solved problem. Where a decision has an expiry condition, it is stated.

### Platform constraints discovered the hard way

- **D-09 · `SpeechDetector` is deliberately absent.** In the shipping SDK it does **not
  conform to `SpeechModule`**, so `SpeechAnalyzer(modules:)` refuses it at compile time.
  Apple has confirmed this is a bug slated for a point update. Voice activity comes from
  `AVAudioEngine` RMS instead — Apple's own suggested fallback. *Expiry: re-add once Apple
  ships the conformance fix.* Session 2's spec asks for it; it is not buildable today.
- **D-22 · Siri voices are unavailable to third-party apps** via `AVSpeechSynthesizer`.
  This is an Apple restriction, not a gap. The build doc's "use a Siri-quality voice" is
  not achievable. Best obtainable are Premium/Enhanced voices the user downloads manually.
  There is also **no API** to list downloadable-but-not-installed voices. Documented in
  README under Known limitations.
- **D-32 · There is NO `FRIDAY.entitlements` file, and adding one would break the build.**
  WeatherKit requires a **paid** Apple Developer Program membership. The owner is on a free
  account. Adding the WeatherKit capability without a paid membership **breaks provisioning
  entirely** — you would trade one non-working tool for a project that will not sign.
  *Expiry: when the owner upgrades to a paid account, add the capability and enable
  WeatherKit on the App ID in the developer portal.*
- **D-38 · The orb must not use `Canvas` while idle.** `Canvas` + `TimelineView(.animation)`
  measures ~30% CPU, ~14% throttled. The success criterion is **under 5% idle**. So idle
  uses one implicit `repeatForever` (render-server driven, near-zero app CPU) and the
  `Canvas` is *constructed only* while listening/thinking/speaking, at a 30fps throttle.
  Do not "simplify" this into one Canvas path.

### Architecture and safety

- **D-34 · Reminder writes are UI-gated, not model-gated.** `ReminderTool` can only
  *stage*; `EKEventStore.save` is reachable only from `confirmReminder()`, which only the
  **Add it** button calls. A 3B model misjudging a turn must never be able to write to the
  owner's real Reminders. Do not let the tool write directly.
- **D-13 · `MicrophoneCapture` was merged into `SpeechInput`.** Two taps on one input node
  conflict; there can be exactly one audio owner. Do not reintroduce a separate capture type.
- **D-14 · `TranscriptionSource` protocol and `PlaceholderTranscriber` were deleted.** Once
  the placeholder was gone the protocol had a single conformer, and CLAUDE.md forbids
  abstractions for single-use code.
- **D-25/26 · One audio session, activated per phase.** Category never churns mid-
  conversation, so echo cancellation stays on. The mic-hears-TTS trap is solved
  *structurally*: the state machine never records and plays simultaneously. Do not add
  category switching.
- **D-27 · Barge-in has a guarded race.** `voice.stop()` resumes the continuation
  `deliver()` awaits; `deliver()` then checks it still owns `.speaking` before touching
  state or the session, otherwise it would clobber the freshly-started listening turn.
- **D-28 · `SpeechOutput.settle()` nils the continuation before resuming.** Both `stop()`
  and the synthesiser's cancel callback land there; double-resume is a crash.
- **D-29 · `.error` must never be a dead end.** It was, for four sessions — the talk button
  died permanently after any failure. Now `fail()` sets a dismissible banner and there are
  **two** recovery paths: tapping the banner, and pressing the orb again. CLAUDE.md's state
  machine requires `any state → error → idle`.
- **D-40/41/42 · Live Activity is driven by a single `didSet` on `state`.** Target
  membership rules in §7 are load-bearing.

### Model and prompt

- **D-16 · `LanguageModelSession` uses the `@InstructionsBuilder` trailing closure**, not
  `instructions:` as a parameter. The tutorial form works for a string *literal*;
  `FridayPersona.instructions` is a `String` **constant**, which is a different thing.
- **D-17 · Only 3 of `GenerationError`'s 9 cases are matched by name**, the rest via
  `default:`. This avoids guessing six case spellings and avoids `@unknown default`
  warnings.
- **D-18 · Context overflow resets the session preserving the persona**, then re-seeds the
  last exchange through the next prompt. A `Transcript`-based init exists but its signature
  could not be confirmed. Overflow also **retries the same input once**, so the turn is not lost.
- **D-35 · Every tool has at least one argument.** Sources mention an `EmptyInput` type for
  argument-less tools but it could not be confirmed, and an empty `@Generable` struct is a
  question mark. Giving each tool a real parameter sidesteps both.
- **D-36 · The persona is deliberately terse.** Five tool schemas share the ~4,096-token
  budget with the persona *and* the conversation. Every persona line costs conversation
  turns before overflow. It still contains every rule from CLAUDE.md's contract.
- **D-21/36 · Two persona lines were authored by Claude, not the owner:** "Never invent
  facts, numbers, or prices" (serves the stock-price criterion) and the anti-over-calling
  rule (serves the Uzbekistan criterion). Flagged so they are not mistaken for spec text.
- **D-37 · No tool return string contains a type or function name.** The surest way to stop
  FRIDAY saying a tool name is to never put one where she can read it. Keep it that way.

### Project file and UI

- **D-04 · `project.pbxproj` is hand-written** at `objectVersion = 56`,
  `compatibilityVersion = "Xcode 14.0"` — deliberately the older, well-understood format
  rather than Xcode 26's synchronized-folder format. Xcode 26 opens it and may offer to
  upgrade. It has been verified to open and build (Session 1).
- **D-05 · No physical `Info.plist`.** Privacy strings are `INFOPLIST_KEY_*` build settings
  with `GENERATE_INFOPLIST_FILE = YES`. All six strings are present in **both**
  configurations: microphone, camera, speech recognition, calendars, reminders, location.
- **D-07 · `AIAvailability` re-checks on `scenePhase == .active`**, not once at launch, so
  toggling Apple Intelligence in Settings and returning shows fresh state.
- **D-31 · Glass is control-layer only.** Apple's guidance: never apply glass to content.
  `glassSurface` is for floating controls (talk button, text field, settings gear);
  `contentSurface` is a solid variant for panels. Do not put glass back on cards or bubbles.
- **D-39 · The orb *is* the talk button.** One focal element, not a control beside a
  decoration.
- **D-24 · FRIDAY waits for the complete reply before speaking**, rather than streaming TTS
  sentence by sentence. Replies are capped at ~3 sentences so the wait is short, and the
  delivery is smooth rather than choppy.
- **The text input is a real feature**, not debug scaffolding. It was originally temporary;
  the owner promoted it deliberately.

---

## 9. Known open issues

1. **README contradicts the app on hardware.** README's Requirements says *iPhone 15 Pro or
   newer*; `Availability.swift` says *iPhone 16 Pro* (matching CLAUDE.md, per owner's
   choice). A17 Pro is the real Foundation Models gate, so README is factually more
   accurate. **Ask the owner which to align to** — do not pick unilaterally.
2. **WeatherKit is non-functional** on a free account (D-32). `WeatherTool` catches the
   failure and reports in character.
3. **`NSSupportsLiveActivities` may not be honoured** as an `INFOPLIST_KEY_*` setting (§7).
4. **Idle CPU is unmeasured.** The <5% criterion drove the orb's design (D-38) but has
   never been checked with Instruments.

---

## 10. Rules of engagement

`CLAUDE.md` governs. The parts that matter most here:

- **API uncertainty rule.** iOS 26 frameworks are newer than most training data. If you are
  not certain of an exact API surface, say so and check the header — do not invent
  plausible names. You have an SDK; use it. `xcrun --sdk iphoneos --show-sdk-path` and the
  `.swiftinterface` files are the ground truth this project has been missing.
- **Simplicity.** Minimum code that solves the stated problem. No features beyond what was
  asked. No abstractions for single-use code.
- **Surgical changes.** Touch only what the task requires. Do not "improve" adjacent code.
  If you notice unrelated dead code, mention it — do not delete it.
- **Verifiable goals.** State the success criterion and how you checked it.
- **Honesty.** Never claim a feature works from a Simulator run. Report failures with the
  actual output. This project's history includes three bugs found by re-auditing that a
  confident summary would have hidden.
- **Commits.** One logical change per commit, present tense, lowercase, e.g.
  `session 7: add app intent and siri shortcuts`. Never commit `.xcuserdata`, build
  artefacts or `DerivedData`.

### Ask the owner rather than guessing

- Which hardware floor to state (§9.1).
- Whether to spend on a paid developer account to enable WeatherKit.
- Anything where two readings of the spec would produce materially different work.
