# FRIDAY iOS — Handover

**Written:** 2026-08-14 (rewritten) · **Repo state:** `main` @ `b16a92a` · **Commits:** 28

This replaces the previous handover, which was written by a cloud session with no Swift
toolchain. Everything it warned about has now been compiled, run on a physical iPhone 16 Pro,
and in several cases found to be wrong. Read this in full before touching anything.

`CLAUDE.md` governs all work and outranks this document where they disagree.

---

## 1. The single most important fact has changed

The old handover's headline was *"nothing since Session 1 has ever been compiled."* That is
no longer true.

Sessions 2–6 now **build clean and run on a physical iPhone 16 Pro** (`iPhone17,1`,
iOS 26.6, device name `KM`). Twelve real defects were found and fixed on device. The
important lesson for whoever reads this next:

> **A zero-warning Swift 6 strict-concurrency build proved almost nothing.**

Three of the twelve were runtime actor-isolation traps that the compiler *cannot* catch,
because isolation inheritance through a non-`Sendable` closure parameter is legal at compile
time and only fails when the system calls back on its own queue. Phase A was necessary and
nowhere near sufficient.

---

## 2. Project identity

| | |
|---|---|
| App | FRIDAY — on-device voice assistant, F.R.I.D.A.Y. persona |
| Owner | Krishna Mathur |
| Bundle ID | `com.krishnamathur.friday` |
| Extension | `com.krishnamathur.friday.FridayActivity` |
| Deployment target | iOS 26.0 |
| Language | Swift 6.0, `SWIFT_STRICT_CONCURRENCY = complete` |
| Test device | iPhone 16 Pro (`iPhone17,1`), iOS 26.6, name `KM` |
| Signing | Personal Team `R9BD597ST6`, free account — profiles expire after 7 days |
| Targets | **Two** — the app and the `FridayActivity` widget extension |

### Building from the command line

Xcode 26.6 is installed but `xcode-select` still points at the Command Line Tools, and
changing it needs an admin password. Every build in this project has used:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project FRIDAY.xcodeproj -scheme FRIDAY \
  -destination 'id=92C25435-7E55-5972-9D03-279CD8C4DF5B' \
  -allowProvisioningUpdates build
```

Install and launch without Xcode:

```bash
xcrun devicectl device install app --device <UDID> <path>/FRIDAY.app
xcrun devicectl device process launch --device <UDID> --terminate-existing com.krishnamathur.friday
```

**Do not use `--console`.** It terminates the app on detach and reports `signal 5`, which
reads exactly like a crash in your code. It cost this project two false diagnoses.

### Getting crash logs (this is the one that matters)

`log collect` needs root. `devicectl device sysdiagnose` fails on this device. The route that
works:

```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type systemCrashLogs --source . --destination ./crashlogs
```

`.ips` files are two JSON documents — a header line, then the body. Parse the body, read
`faultingThread`, and map `frames[].imageIndex` through `usedImages[]`. Every crash in this
session was diagnosed this way in about a minute.

### Environment prerequisites (owner-side)

- **Apple Intelligence must be ON.** Number-one cause of "it doesn't work".
- **Physical device only.** Never claim a feature works from a Simulator run.
- **Trust the developer profile** after any fresh install: Settings → General → VPN & Device
  Management. Deleting the app removes this, and the next launch fails with a security error.
- **Voice quality** needs a Premium or Enhanced English voice downloaded in Settings →
  Accessibility → Live Speech → Voices.

---

## 3. What is built

35 Swift files across two targets.

| Dir | Files | Contents |
|---|---|---|
| `FRIDAY/` | 1 | `FRIDAYApp.swift` |
| `Core/` | 5 | `FridayEngine`, `FridayState`, `FridayPersona`, `ConversationTurn`, **`Intent`** |
| `Intelligence/` | 3 | `Availability`, `Generables`, `LanguageEngine` |
| `Speech/` | 3 | `AudioSessionManager`, `SpeechInput`, `SpeechOutput` |
| `Tools/` | 6 | `FridayTool`, `TimeTool`, `DeviceTool`, `WeatherTool`, `CalendarTool`, `ReminderTool` |
| `UI/` | 9 | `ContentView`, `ConversationView`, `OrbView`, `TalkButton`, `SettingsView`, `AmbientBackground`, `GlassSurface`, `FridayTheme`, `Haptics` |
| `LiveActivity/` | 3 | `FridayAttributes`, `LiveActivityController`, `FridayLiveActivity` |
| `Intents/` | 2 | `AskFridayIntent` (+ `FridayAnswer`, `FridayShortcuts`), `StartListeningIntent` |
| `FridayActivity/` | 3 | `FridayActivityBundle` (`@main`), `FridayListenControl`, `FridayLockWidget` |

### Per-session status

| Session | Built | Verified on device |
|---|---|---|
| 1 — availability + app shell | ✅ | ✅ green "Ready" |
| 2 — speech input | ✅ | ✅ live transcription, stable finals, repeated turns |
| 3 — language engine + persona | ✅ | ✅ in character, says "boss" |
| 4 — speech output | ✅ | ✅ speaks aloud, barge-in cuts off cleanly |
| 5 — tools | ✅ | ✅ all four correct — but see §5, routing changed |
| 6 — orb, haptics, Live Activity | ✅ | ✅ Dynamic Island renders; idle CPU 2% in Release |
| 7 — App Intents, Siri, Control Centre | ✅ | ✅ Siri speaks answers; control and widget both launch listening |
| 8 — Phase 2 LiveKit bridge | ❌ out of scope | ❌ |

---

## 4. Status

**Phases A, B and C are complete.** What remains:

### Every criterion passes on device

Sessions 1–7 are fully verified, including barge-in, airplane mode, a phone call
mid-listen, ten turns, the Dynamic Island, idle CPU at 2%, denied microphone and calendar
permissions, and Apple Intelligence toggled off.

The toggle test is worth recording in detail, because it demonstrates the routing rewrite
(§5) more clearly than anything else: with Apple Intelligence **off**, the red
"Apple Intelligence Off" card appears via D-07's `scenePhase` re-check — and **"what time
is it" still answers correctly**, because time routes through Swift and never reaches the
model. Only conversational turns degrade. Half the app keeps working with the model gone.

### Phase C is complete

App Intent, Siri shortcuts, Control Centre control and Lock Screen widget all built and
verified. Two spec items could not be met as written — see D-51 and D-52.

### Suggested next work

Hardening (Router phrasings, the denied-permission paths), then either Session 8's LiveKit
bridge or App Store preparation, which needs a paid account.

---

## 5. Architecture change — routing moved out of the model

**This deviates from `Master_Build.md` §11 and was the owner's explicit decision. Do not
revert it on the strength of the build doc.**

The ~3B model could not route tools reliably. On device it answered *"what can you do"* with
the battery level, sent *"what time is it"* to the reminder tool, staged a reminder titled
*"What time is it?"*, and wedged turns on a weather tool that cannot work. Three rounds of
tightening tool descriptions and persona rules did not fix it.

So:

- **`Core/Intent.swift`** matches intent in Swift, calls the tool directly, and composes the
  sentence. A tool can no longer fire on a turn that was not routed to it — mis-routing is
  impossible rather than merely less likely.
- **Factual answers are written in Swift**, so a number can never be paraphrased into a
  different number and "boss" is always present.
- **`LanguageModelSession` registers no tools.** It only handles conversational turns, and
  the persona and conversation get the entire ~4,096 token budget four schemas used to share.

Reversible: every tool still conforms to `Tool` and is unchanged. Known limit: unanticipated
phrasings fall through to chat, and adding one is a one-line change in `Router`.

---

## 6. API seams — all resolved

The old §5 listed five unverified seams. Every one was **correct as written**. Verified
against the shipping `.swiftinterface` files in the iPhoneOS 26.5 SDK.

| # | Surface | Verdict |
|---|---|---|
| S-1 | `AssetInventory.assetInstallationRequest(supporting:)`, `.progress`, `downloadAndInstall()` | ✅ correct |
| S-2 | `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` | ✅ correct — `async`, Optional |
| S-3 | `analyzer.finalizeAndFinishThroughEndOfInput()` | ✅ real, not invented |
| S-4 | `LanguageModelSession` `@InstructionsBuilder` init | ✅ compiles |
| S-5 | `GenerationError` case names | ✅ all three correct; there are exactly nine cases |
| — | `SystemLanguageModel.Availability.UnavailableReason` | ✅ exactly three cases, all correct |

Two corrections worth carrying forward:

- **D-16's reasoning was wrong.** A `String?` overload exists and accepts a String constant
  perfectly well. The builder form is a preference, not a requirement.
- **`LanguageModelSession(model:tools:transcript:)` exists.** D-18 said its signature could
  not be confirmed; it can. That is a cleaner overflow-recovery path than re-seeding.

One thing the old doc never listed but which mattered: **`ResponseStream`'s `Element` is a
`Snapshot`, not the `PartiallyGenerated` type.** `snapshot.content.spoken`, not
`partial.spoken`. That was a real compile error.

---

## 7. Concurrency — what actually broke

The old §6 listed seven "escape hatches" and guessed which would fail. It guessed wrong in
both directions.

**Removed as unnecessary:** `nonisolated(unsafe) let converter` — `AVAudioConverter` *is*
Sendable in the iOS 26 SDK, and the compiler says so.

**The two crashes, both invisible to the compiler:**

| Site | Callback runs on | Fix |
|---|---|---|
| `SpeechInput.requestRecognitionAccess` | TCC's background XPC queue | `nonisolated` |
| `SpeechInput.startCapture` audio tap | `RealtimeMessenger` audio queue | `@Sendable` on the closure |

Both are the same fault: a `@MainActor` type's closure inherits isolation, and the system
invokes it elsewhere. `AVAudioNodeTapBlock` is not `NS_SWIFT_SENDABLE`, so nothing warns.

**The old doc predicted `SpeechOutput` and `WeatherTool` would share the fault. They do
not** — both put their callbacks in a separate non-isolated `NSObject`, which is exactly why
they are safe. That pattern is the fix; copy it.

**Two more lifecycle bugs, no compiler involvement:**

- **`SpeechTranscriber` is single-use.** `stop()` calls
  `finalizeAndFinishThroughEndOfInput()`, which permanently finishes its results stream.
  Reusing one across turns traps inside the framework in
  `SpeechAnalyzer.setWorkers(for:reusingFrom:)`. It is now rebuilt per turn; the *locale* is
  the durable state.
- **A wedged turn is unrecoverable.** `startListening` guards on `state == .idle`, so a hung
  `.thinking` kills the app until relaunch. `FridayEngine.respondWithDeadline` gives up after
  20s. It deliberately does **not** use a task group: a task group awaits every child, and an
  unresumed `withCheckedContinuation` is not cancellable, so the deadline could never fire.
  The losing side is abandoned instead.

---

## 8. The widget extension exists

`FridayActivity` was created by hand-editing `project.pbxproj` in the existing
`objectVersion = 56` format, preserving D-04. Membership, verified in the build log:

| File | App | Extension |
|---|---|---|
| `FridayAttributes.swift` | ✅ | ✅ |
| `FridayLiveActivity.swift` | ❌ | ✅ |
| `LiveActivityController.swift` | ✅ | ❌ |
| `FridayActivityBundle.swift` | ❌ | ✅ |
| `StartListeningIntent.swift` | ✅ | ✅ |
| `FridayListenControl.swift` | ❌ | ✅ |
| `FridayLockWidget.swift` | ❌ | ✅ |

**`NSSupportsLiveActivities` IS honoured** as an `INFOPLIST_KEY_` build setting — verified
`true` in the built Info.plist with `plutil`. The old §9.3 doubt is settled.

**Live Activity status:** `Activity.request` succeeds — a temporary `lastFailure` diagnostic
in `LiveActivityController` reports nothing. But the activity has never been *seen*. iOS does
not render an app's own Live Activity in the Dynamic Island while that app is frontmost, so
testing it means backgrounding the app mid-turn. There is a design problem underneath: FRIDAY's
states last seconds, so a Live Activity is close to unobservable until Session 7's Control
Centre entry point exists.

**Remove the `lastFailure` diagnostic** once Session 6 is verified. It is marked temporary in
both `LiveActivityController` and `ContentView`'s footer.

---

## 9. Decision log — additions

The old §8 still stands except where noted. New decisions from device work:

- **D-43 · Routing is done in Swift, not by the model.** See §5. Owner's decision, deviates
  from Master Build §11.
- **D-44 · Factual answers are composed in Swift.** A 3B model paraphrasing a number can
  quietly change it — the worst failure an assistant has. Also fixes verbatim tool echo.
- **D-45 · Greedy sampling.** Default random sampling produced "what time is it" answered
  with "what's for dinner". `GenerationOptions(sampling: .greedy)`. **No
  `maximumResponseTokens`** — a cap landing mid-structure leaves guided generation's value
  incomplete and throws "Empty reply".
- **D-46 · `WeatherTool` is not registered** (`weatherIsUsable = false`). On a free account
  WeatherKit can never succeed, and every call spent a location fix before failing. This
  follows D-32 rather than reversing it. Flip one constant when the account is upgraded.
- **D-47 · Hardware floor states both.** `Availability.swift` says iPhone 15 Pro or newer
  (the real A17 Pro gate); the README notes only 16 Pro is verified. Closes old §9.1.
- **D-48 · `AmbientBackground` is a `.background`, not a `ZStack` sibling.** Its blobs have
  fixed frames up to 470pt and a `ZStack` sizes to its largest child, so the whole interface
  was laid out 470pt wide on a 402pt screen and clipped ~34pt at each edge. A `.background`
  is proposed the primary view's size and can never grow it.
- **D-49 · CoreLocation is bounded at 4s.** It is not obliged to call back; authorised with
  no fix, it stays silent and no delegate method fires. Must be bounded at the source — no
  deadline upstream can rescue an unresumed continuation.

- **D-50 · The resting orb does not breathe.** Release idle CPU went 8% → 6% → 2%
  against a <5% budget. D-38 was right that `Canvas` was the enemy and its fix is
  correct — no `Canvas` exists at idle — but it budgeted the orb in isolation and never
  accounted for Liquid Glass, which re-samples whatever animates beneath it. `TalkButton`
  wraps the orb in `.glassEffect`, so a permanently breathing orb meant permanently
  re-blurring glass. Three continuous animations ran at idle, not one. Fixed in order: the
  ambient field holds still at rest, the status chip's shadow is static, the resting orb is
  frozen. **This contradicts Master Build §12's "idle: slow ambient breathing pulse"** —
  the owner chose it over dropping `.interactive()` from the glass.
- **D-51 · Siri cannot take the question in one utterance.** Interpolating the `String`
  parameter into an `AppShortcut` phrase fails to build: *"AppEntity and AppEnum are the
  only allowed types"*. So Master Build §13's "Hey Siri, ask FRIDAY what time it is" is not
  achievable. "Ask FRIDAY" prompts for the question and speaks the answer. A fixed
  `AppEnum` of canned questions would buy the one-shot phrasing at the cost of only ever
  answering a hardcoded list.
- **D-52 · The Lock Screen widget shows no timestamp.** A widget runs in its own process,
  so reading anything the app wrote needs an App Group — a capability requiring a paid
  membership, which on a free account risks breaking provisioning outright (D-32). Unlike
  the Control Centre control there is no `openAppWhenRun` escape hatch, because a widget
  must render before anyone taps it. It is a launcher instead.

### D-18 is now probably unreachable — do not delete it, do not trust it

`LanguageEngine` still carries the full context-overflow path: catch
`exceededContextWindowSize`, rebuild the session preserving the persona, re-seed the last
exchange through the next prompt, and retry the same input once so the turn is not lost.

**Ten consecutive chat turns on device produced no reset.** Dropping the tool schemas (§5)
handed the persona and the conversation the entire ~4,096 token budget that four schemas
used to share, so overflow is now much further away than when D-18 was written.

Three things follow, and they pull in different directions:

- It is **not dead code.** A long enough conversation still reaches it, and re-registering
  tools would bring it straight back into play.
- It is **effectively untestable through the UI** at present. Nobody has seen it run.
- It is therefore **unverified**, and must not be described as working. The reset logic, the
  carry-over re-seed and the single retry have never executed on device.

If you need to exercise it, the practical route is to temporarily re-register the tools in
`makeSession()`, which restores the old budget pressure, rather than typing until it
happens.

### D-09 needs re-deciding

**`SpeechDetector` now conforms to `SpeechModule`** in the shipping SDK:

```swift
final public class SpeechDetector : Speech.SpeechModule
```

D-09's stated expiry — *"re-add once Apple ships the conformance fix"* — has been met. The
standing instruction "do not add it, it will not compile" rests on a premise that is now
false. The `AVAudioEngine` RMS fallback works, so there is no urgency; this is the owner's
call, not the next session's.

---

## 10. Known open issues

1. **`WeatherTool` is dead code** while `weatherIsUsable` is false. Deliberate, not an
   oversight — see D-46.
2. **`LanguageEngine.reminders` is now unused** since the session registers no tools. Left in
   place because re-registering tools would need it.
3. **Keyword routing has gaps.** "Do I have time for coffee?" routes to the clock.
   One-line fixes in `Router` as they turn up.
4. **Free-account provisioning expires every 7 days.** The app stops launching until rebuilt.
5. **D-18's overflow path is unverified** and probably unreachable in normal use — see the
   section above. Written, correct on inspection, never observed running.
6. **`WeatherTool`, D-09 and the paid account** remain the three standing decisions.

---

## 11. Rules of engagement

`CLAUDE.md` governs. The parts that earned their keep this session:

- **Measure, don't reason.** The layout bug survived two confident, well-argued, wrong
  diagnoses. One `onGeometryChange` printing the container width settled it in a single pass.
  When a hypothesis fails, instrument — do not form a second hypothesis.
- **Honesty.** Several "it works" reports turned out to be crashes that iOS relaunched fast
  enough to look fine. Verify against crash logs, not against the screen.
- **Simplicity.** Two defects in this session were caused by speculative additions —
  a `maximumResponseTokens` backstop nothing asked for, and a deadline built on a task group
  that could not fire. Minimum code is not a style preference.
- **Ask rather than guess.** The routing rewrite was the owner's decision, presented with
  options and trade-offs, after prompt-tuning had failed three times.
