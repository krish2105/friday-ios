# FRIDAY iOS — Handover

**Written:** 2026-08-14 (rewritten) · **Updated:** 2026-08-15 (§3, §4, D-45, D-53–D-57, §10)
**Repo state:** `main` @ `9c7d252` · **Commits:** 46

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

40 Swift files across two targets.

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
| `Vision/` | 3 | `TextScanner`, `DocumentCamera`, `ReceiptReader` |
| `Language/` | 2 | `Bilingual`, `Translator` |
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

### Document reading — all three stages are in

`Vision/` is a feature after Phase C, in three stages, all now committed. Stage 1
(`TextScanner`, `RecognizeDocumentsRequest`), stage 2 (photo library and live camera entry
points, routed through `Router`), stage 3 (`@Generable` receipt extraction — see D-57).

Stages 1 and 2 were confirmed by the owner on the 16 Pro on 2026-08-15: the camera route
scans a page and FRIDAY reads it back. D-53's repetition fix was confirmed in the same pass.
**Stage 3 has not been run against a real receipt** — its Swift half passes 25 cases,
including every way of getting the total wrong, but no receipt has been photographed.

### Suggested next work

Photograph a real receipt (§10.9) and type a Hindi sentence (§10.8) — both are built and
neither has been run. Then hardening (Router phrasings, the denied-permission paths), or
Session 8's LiveKit bridge, or App Store preparation, which needs a paid account.

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
- **D-45 · Greedy sampling.** ~~Default random sampling produced "what time is it" answered
  with "what's for dinner". `GenerationOptions(sampling: .greedy)`.~~ **Half superseded on
  2026-08-15 — see D-53.** The `maximumResponseTokens` half still stands: **no
  `maximumResponseTokens`**, because a cap landing mid-structure leaves guided generation's
  value incomplete and throws "Empty reply".
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

- **D-53 · Seeded top-3 sampling, replacing greedy — and a Swift-side loop guard.**
  `GenerationOptions(sampling: .random(top: 3, seed: 1))`.

  On device on 2026-08-15, *"what languages do you know"* answered with the same run of
  language names over and over — Marathi, Nepali, Urdu, Hindi, Bengali, Telugu, Marathi,
  Tamil, Kannada, Malayalam, Gujarati, Punjabi, Sindhi, and round again — until the 20s
  deadline killed it. FRIDAY then said *"that one's taking too long, boss"* about a turn that
  was working exactly as instructed, and the retry failed differently again.

  Root cause was **both halves of D-45 interacting**. `.greedy` takes the argmax at every
  step, so once the model enters a repetition cycle it re-picks the same tokens forever,
  deterministically; and with no `maximumResponseTokens` nothing bounded it.

  Two things follow that are worth carrying forward:

  - **The deadline was not at fault, and the intuitive fix was the wrong one.** It fired on a
    turn that was actively producing tokens. Making it an *inactivity* deadline — the obvious
    move — would have hung the app instead of erroring, because an active loop never goes
    inactive. Read the symptom before rewriting the timer.
  - **`seed:` dissolves D-45's dilemma.** D-45's real requirement was reproducibility, and
    `.random(top:seed:)` takes an optional seed, which delivers it — the same prompt gives
    the same reply — while `top: 3` stays near the argmax. Cycles break because the RNG state
    has advanced by the time a repeated context comes round again. D-45's *other* reason for
    greedy, that random sampling answered "what time is it" with "what's for dinner", stopped
    applying at **D-43**: time is answered in Swift now and never reaches the model at all.

  `LanguageEngine.trimmedAtRepetition` is the second layer, because no sampling mode is
  guaranteed loop-free. A sixty-character window that has already appeared earlier in the
  reply is a cycle, not a coincidence; the stream stops there and keeps the text from before
  the repeat, which is the part the model actually meant. On the real 5,846-character runaway
  that salvages a 128-character list of languages, so the turn answers instead of failing.
  Checked against five realistic replies — a 333-char elaboration and a 216-char
  non-repeating list among them — none are touched.

- **D-54 · "Read this" opens the camera, not the photo library.** `Router` splits
  `.scan(source:)` on whether he named something already on the phone — "this photo", "that
  screenshot", "my photos" go to the library; everything else points the camera. A
  demonstrative with no such noun means he is holding the thing up, and routing that through
  the photo library is the wrong default for something meant to be a daily driver. One-line
  flip in `Router.scanSource(in:)`.

- **D-55 · The camera is VisionKit's document scanner, not a hand-built `AVCaptureSession`.**
  Accuracy before effort: it corrects the page perspective before handing the image over, and
  `RecognizeDocumentsRequest` reads a flat page far better than a trapezoid one. Multi-page,
  edge detection and the torch come with it. The cost is that the chrome is Apple's rather
  than FRIDAY's glass; a bespoke capture UI is a drop-in replacement that would have to
  re-earn the perspective correction.

  Two seams here, both of which would have cost a debug cycle if guessed:

  - **`perform(on: Data)` exists.** Stage 1's commit message says it does not. It matters
    because a portrait photo is landscape pixels *plus* an EXIF tag, and
    `UIImage(data:)?.cgImage` drops the tag and hands Vision a sideways page. `TextScanner`
    takes `Data` for exactly this reason.
  - **VisionKit's `apinotes` are wrong for this target.** They rename `didFailWithError:` to
    `documentCameraViewController(_:didFailWith:)`. The compiler wants the unabbreviated
    form, and the short one only *warns*, because the requirement is optional — so a scanner
    failure would have had no handler at all. The header was not the authority; the compiler
    was.

- **D-56 · Hindi sits either side of the model, never inside it.** Typed Hindi is translated
  to English before `Router` sees it, and the finished English sentence is translated back
  before FRIDAY says it. `Router`, `Lookup`, the persona and all 34 truth-table cases are
  untouched, because nothing downstream of `FridayEngine.submit` ever sees anything but
  English.

  Forced by what the frameworks actually support, measured on 2026-08-15:

  | Layer | Hindi |
  |---|---|
  | `SpeechTranscriber.supportedLocales` | **no** — 30 locales, none Hindi |
  | `SystemLanguageModel.supportedLanguages` | **no** — 23 languages; `supportsLocale(hi_IN)` false |
  | `LanguageAvailability.supportedLanguages` | **yes** — 38 languages incl. `hi-Deva-IN`, both ways |
  | `AVSpeechSynthesisVoice` | **yes** — `Lekha`, `hi-IN` |

  Three consequences worth carrying forward:

  - **Hindi cannot be spoken to her, only typed.** The transcriber has no Hindi locale — not
    a poor one, none. A platform limit in the same class as the wake word: documented, not
    worked around. `Bilingual.tongue(of:)` detects Devanagari, so **romanised Hindi ("kya
    haal hai") reads as English** and goes to the model as-is. Script is deterministic where
    a statistical recogniser on three words is not, and the wrong answer here costs a good
    English turn two translation hops.
  - **D-44 is enforced against the translator, not trusted.** Factual answers carry the
    numbers D-44 exists to protect, and translating one hands that number back to a model.
    So `Bilingual.preservesNumbers` checks every digit run survived — folding Devanagari
    digits onto ASCII, since ८७ preserves 87 perfectly well — and the caller keeps the
    **English** sentence if one went missing. Right answer in the wrong language beats a
    fluent Hindi sentence quoting the wrong time. Chat turns skip the check: no number in
    them is load-bearing, and dropping to English mid-conversation reads worse.
  - **The pack cannot be downloaded from inside the app.** A session built with
    `installedSource:` reports `canRequestDownloads == false` and throws
    `TranslationError.notInstalled`. So `SettingsView` reports the state and points at
    Settings → Apps → Translate → Downloaded Languages — the same call the Premium voices get,
    and it avoids needing a SwiftUI-attached session at all.

  One concurrency note. `TranslationSession` is not `Sendable`, so a *stored* one cannot be
  handed to an `async` method — *"sending `self.session` risks causing data races"*. The
  compiler is right rather than pedantic: a turn suspends inside `translate`, and the next
  turn would reach the same session while the first is still in it. A session is therefore
  built per call and never stored. `@preconcurrency import` would have demoted this to a
  warning, which is worse twice over — the race stays, and a zero-warning build stops meaning
  anything.

- **D-57 · The model selects, Swift verifies. Nothing unverified is ever spoken.**
  Stage 3 asks a ~3B model to read money off a photograph, which is D-44's failure with the
  stakes raised: "TOTAL 47.30" coming back as 43.70 is a confidently wrong answer about the
  boss's money. Guided generation gives a typed `Receipt`, but **typed is not true** — the
  fields are still whatever the model produced.

  So the model's job is reduced to *selection*: each `@Guide` asks for the value **copied
  exactly as printed**, which turns the answer into a claim about the page that Swift can
  check. `ReceiptReader.verified` then does the checking, and it is the whole feature.

  Three gates, each cheap, each declining costs only the ordinary summary:

  1. `looksLikeReceipt` — Swift decides whether an extraction is worth its seconds. Needs a
     billing word **and** a currency amount; either alone matches an essay about totals or a
     price on a poster. The model is never asked whether it should be asked, which is the
     same division of labour as `Router`.
  2. The model extracts, on a session of its own — the conversational one carries the persona
     and would keep the whole page in its transcript, steering every later reply (D-36).
  3. `verified` refuses anything it cannot find. **The total must appear on a line that says
     it is the total**, and that is the part worth understanding: searching the whole page
     proves only that the number was printed *somewhere*, so the tax line, the subtotal, the
     bill number and the card digits would all have passed. Requiring the label pins which
     number it is. Merchant and date only have to appear anywhere, and are **blanked rather
     than rejected** when they do not — a receipt without a merchant is still worth saying,
     a receipt with the wrong number is worse than none.

  The spoken line is composed in Swift from verified fields, because the model has already
  had its turn and letting it write the sentence hands back the number it was just checked on.

  25 cases pass, including every way of being wrong: an invented total, a transposed one, the
  subtotal, a GST line, a line item, the bill number, the card digits. A receipt that prints
  its total on the *following* line is rejected and falls back to the summary — the right way
  round, since a missed extraction costs a nicety and a wrong one misreports what he spent.

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
3. **Keyword routing has gaps.** ~~"Do I have time for coffee?" routes to the clock.~~ That
   example is stale — it routes to chat, correctly, and has since the needles became
   multi-word. The general point stands: an unanticipated phrasing falls through to chat, and
   adding one is a one-line change in `Router`. A 34-case truth table now covers the routes;
   extend it rather than testing by hand.
4. **Free-account provisioning expires every 7 days.** The app stops launching until rebuilt.
5. **D-18's overflow path is unverified** and probably unreachable in normal use — see the
   section above. Written, correct on inspection, never observed running.
6. **`LanguageEngineFailure.other` still discards its own description.** Five distinct faults
   — "Already responding", "Empty reply", and the six `GenerationError` cases `classify`
   folds into `default` — reach the user as one sentence and are recorded nowhere. That is
   correct for the *spoken* line, which must stay in character, but it means the next
   `.other` bug starts from zero again. The temporary diagnostic that found D-53 has been
   deleted (it did its job); if another one is needed, that shape works and took ten minutes.
7. **`WeatherTool`, D-09 and the paid account** remain the three standing decisions.
8. **Hindi is built but NOT verified on device.** See D-56. It compiles with zero warnings
   and its two pure-text pieces pass 18 cases, but no Hindi has ever gone through the app:
   the language pack is not downloaded on the build Mac, so the translator has never actually
   run. Until someone downloads Hindi in Settings → Apps → Translate and types a Devanagari
   sentence, this is compiled-only — per §1, that proves almost nothing. Latency is the first
   thing to watch: two translation hops land on top of a turn that already races a 20s
   deadline.
9. **Stage 3 has never met a real receipt.** See D-57. Its Swift half — the heuristic and
   the verification — passes 25 cases, but that half is only *half*: nothing has confirmed
   the model returns copied values rather than reformatted ones on a genuine photographed
   receipt. If extraction never fires, the most likely cause is the model reformatting the
   total rather than copying it, and the diagnosis is to compare `Receipt.total` against the
   `TextScanner` transcript. Rejection is the safe direction, so this fails quietly to the
   ordinary summary — which also means it can be broken without looking broken.
10. **Superseded — kept for the measurement.** Hindi conversational support. Measured
   on 2026-08-15, not recalled: `SystemLanguageModel.supportedLanguages` returns 23
   languages and Hindi is not among them — `supportsLocale(hi_IN)` is `false`. Independently,
   `SpeechTranscriber.supportedLocales` returns 30 locales with **no** Hindi at all, so it
   cannot even be transcribed. A Hindi TTS voice (`Lekha`, `hi-IN`) *is* installed, so the
   only Hindi-capable layer is the one that speaks. What is achievable is the Swift-composed
   half — `Router` needles and `Lookup`'s sentences are code, not model output, so the time,
   date, device, calendar and reminder answers could be written in Hindi and spoken with
   Lekha. Chat turns cannot. **Caveat, and it is D-09's caveat exactly:** this was measured
   on the Mac, where Apple Intelligence is not enabled. Re-confirm on the iPhone before
   building anything on it.

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
