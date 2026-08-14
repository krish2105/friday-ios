# FRIDAY iOS — Handover

**Written:** 2026-08-14 (rewritten) · **Updated:** 2026-08-15 (§3, §4, D-09, D-45, D-53–D-67, §10)
**Repo state:** `main`, stage 3 landed at `15bca6f` · **Commits:** 47

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

60 Swift files across two targets.

| Dir | Files | Contents |
|---|---|---|
| `FRIDAY/` | 1 | `FRIDAYApp.swift` |
| `Core/` | 7 | `FridayEngine`, `FridayState`, `FridayPersona`, `ConversationTurn`, **`Intent`**, `EventService`, `Deadline` |
| `Intelligence/` | 3 | `Availability`, `Generables`, `LanguageEngine` |
| `Speech/` | 3 | `AudioSessionManager`, `SpeechInput`, `SpeechOutput` |
| `Tools/` | 10 | `FridayTool`, `TimeTool`, `DeviceTool`, `WeatherTool`, `CalendarTool`, `ReminderTool`, `ContactTool`, `MotionTool`, `ReckonTool`, `TimerTool` |
| `UI/` | 13 | `ContentView`, `ConversationView`, `OrbView`, `TalkButton`, `SettingsView`, `AmbientBackground`, `GlassSurface`, `FridayTheme`, `Haptics`, **`ActionSlot`**, **`InputBar`**, **`StatusHeader`**, **`CapabilitiesSheet`**, **`HeroPanel`** |
| `LiveActivity/` | 3 | `FridayAttributes`, `LiveActivityController`, `FridayLiveActivity` |
| `Intents/` | 3 | `AskFridayIntent` (+ `FridayAnswer`, `FridayShortcuts`), `StartListeningIntent`, `FridaySnippet` |
| `Vision/` | 8 | `TextScanner`, `DocumentCamera`, `ReceiptReader`, `BoardingPassReader`, `BarcodeReader`, `LiveScanner`, `PDFReader`, `CardReader` |
| `Language/` | 3 | `Bilingual`, `Translator`, `Tongues` |
| `Notify/` | 1 | `FridayNotifier` |
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

All three confirmed by the owner on the 16 Pro on 2026-08-15, along with stages 4–7 and the
D-61 hang fix.

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

- **D-58 · Stage 4 — FRIDAY acts, and every action is still gated.** Four features, all free
  on a Personal Team: her own reminder nudges, contacts, calendar writes, and steps. Two new
  usage strings (`NSContactsUsageDescription`, `NSMotionUsageDescription`) plus
  `NSCalendarsWriteOnlyAccessUsageDescription`. **No capability, nothing that touches
  provisioning.**

  Four owner decisions, taken at the design gate:

  - **A Settings toggle decides who nudges.** Both alerting is redundant, neither loses the
    reminder. On, FRIDAY schedules a local notification and the `EKReminder` is saved
    *without* an alarm; off, the alarm goes back and she stays quiet. The reminder is written
    to Apple Reminders either way, so D-34 holds and it outlives the app being deleted. The
    alarm is the **fallback**, not a second alert — added only when FRIDAY could not take the
    job.
  - **Calling is staged, never dialled.** `Router` has known phrasing gaps and a false
    positive rings a real person. Same shape as D-34.
  - **Name matching covers nicknames and relations** — and a synonym table is what makes it
    work. Nobody files a related name as "mom"; the Contacts app offers **"mother"**. Without
    the mapping the headline case fails while "mother" succeeds, which the fixture test caught
    and nothing else would have. Hindi kinship terms are in the table too, since D-56.
  - **Notifications carry Done and Snooze.**

  **`CMPedometer` is the free route to a HealthKit-gated feature.** HealthKit cannot be signed
  on this account (D-32); CoreMotion needs only a usage string. Its history is **seven days**,
  so anything older is declined rather than answered with a silent zero — and *no data* is
  kept distinct from *zero steps*, because a phone left on a desk did not walk nowhere.

  Two Swift 6 lessons, both the same shape as `Translator`'s: `CNContact` and `CMPedometerData`
  are **not `Sendable`**, so neither may leave the queue that produced it. Both are mapped to
  small `Sendable` value types at the boundary — `Person` and `Reading` — rather than reaching
  for `@preconcurrency`. Mapping `CNContact` to `Person` had a second payoff that was worth
  more than the compiler fix: it made the matching **pure**, so "does *mom* find the right
  person" is answerable against fixtures instead of only on a device with a real address book.

  The routing truth table now runs **47 cases** and re-runs every previously passing one. That
  caught four real bugs in one pass: `when's Priya's birthday` resolving to a person called
  "when", and `call me back later` / `call it off` both staging calls to nobody. Four new
  needle groups is the largest single addition `Router` has had; extend the table, never test
  routing by hand.

- **D-59 · Stage 5 — translate anything, and a second structured extractor.** Two features
  shipped of the three designed. The third was **dropped on evidence**, which is the part
  worth reading.

  **`NLLanguageRecognizer` cannot detect romanised Hindi, and is confidently wrong.** It was
  going to close the "kya haal hai" gap as a second opinion after `Bilingual.tongue`'s script
  test. Measured on 2026-08-15:

  | Input | Detected |
  |---|---|
  | "kya haal hai boss" | Dutch, 0.68 |
  | "mujhe kal subah yaad dilana" | **Indonesian, 1.00** |
  | "aap kaise hain" | Finnish, 0.38 |

  Not one is Hindi and the worst is wrong at full confidence, so wiring it in would have sent
  ordinary English turns through two translation hops on the strength of noise. Devanagari,
  English and French all detect at ≥0.98, so the framework is sound — romanised text simply
  is not its problem. **The romanised-Hindi gap stays open, and this is why.** Do not
  reach for `NLLanguageRecognizer` to close it.

  **Translation into any of the 22 supported languages.** `Tongues` maps spoken names, and
  aliases people actually use, onto codes. Two gates are required together: a phrasing that
  asks for a translation *and* a word that is genuinely a language — either alone over-matches
  ("what's the time in London" has the shape, "I'm learning French" has the language).
  Checked **before every other route**, because the phrase being translated can contain
  anything: "how do you say what time is it in French" would otherwise be answered with the
  clock.

  The reply is the translation and nothing else — no "boss", no English frame — spoken in a
  voice for that language via `SpeechOutput.speak(_:in:)`. Hearing it pronounced properly is
  the whole value of the question, and an English voice wrapping a French phrase ruins the
  one part that matters. It is a quotation, like the recognised text of a scanned page, which
  also carries no form of address. **Each language needs its own pack**, so "not downloaded"
  is the ordinary case and the line always names which language.

  **`BoardingPassReader` generalises stage 3.** Deliberately the same shape as
  `ReceiptReader` — cheap Swift gate, model selects, Swift refuses anything not on the page —
  because that shape is what was worth generalising, not the receipt specifics. Unlike a
  receipt there is no single field carrying all the risk, so *every* field is verified and any
  that fails is simply not said; only a missing flight number rejects outright.

  Both gates were caught wrong by tests before they ever ran on a device:
  `containsFlightNumber` scanned single tokens and so **missed `6E 5231`**, the commonest way
  a pass prints it, meaning the feature would never have fired; and "terminal" and "class"
  had to leave the travel-word list because a card receipt prints "Terminal ID".

  Routing truth table is now **58 cases**, all re-run every time.

- **D-60 · Stage 6 — codes, files and a live viewfinder.** `ScanSource` grows from two to
  four: `.camera`, `.library`, `.files`, `.live`. Free throughout — `fileImporter` hands back
  a security-scoped URL and needs no entitlement, exactly as `PhotosPicker` needs no photo
  permission.

  **A QR code is untrusted input from the physical world**, and this is the security decision
  in the stage. Anyone can print a sticker and put it on a parking meter, so nothing is
  followed automatically. Three layers:

  1. Only `http` and `https` with a real host become an openable link. `javascript:`,
     `data:`, `file:`, `tel:` and custom app schemes are all reported as **plain text** —
     tested, because a `data:` URL handed to the system is how a scanned code becomes a
     script.
  2. Opening is staged on a card showing the **whole** address, not a tidied host. Reading
     where a link actually goes is the only defence there is, and a friendly name removes it.
  3. A Wi-Fi code's password is parsed and **never spoken or shown**. Reading a password
     aloud in a room is not a feature. The spoken line names the network only.

  The spoken line names a link's **host**, not its address — reading a tracking-laden URL out
  loud helps nobody, and the card carries the full thing for anyone who wants it.

  **`LiveScanner` is not a duplicate of `DocumentCamera`**, and the split is by what you are
  looking at. A page wants a shutter, edge detection and perspective correction; a QR sticker
  or a shop sign wants none of the three and is hindered by all of them. Nothing is captured
  until a tap — `didTapOn` is the only route out — so the viewfinder can be open without
  reading anything, which is the right default for a camera pointed at the world. The system
  scanner has no chrome, so the close button is ours or there is no way back.

  **`PDFReader` tries the text layer first and OCR second, per page.** A born-digital invoice
  carries its characters, and photographing them would discard perfect data to introduce OCR
  errors into something that had none; a scan has no characters at all. Per page rather than
  per document, because a signed contract is both. Pages are rendered at **2×** — 1× is about
  72 dpi and below what recognition needs for body text — and capped at eight, since more
  cannot fit the ~4,096 token budget anyway and refusing is honester than summarising the
  first eight as though they were the whole document.

  `FridayEngine.present(scanned:)` was extracted so **a PDF is answered exactly as a
  photograph is** — receipt, boarding pass, read-aloud or summary. Where the words came from
  should change nothing about what happens to them, and two copies would have drifted.

  Routing truth table: **65 cases**. It caught "what's this QR code" falling through to chat —
  that phrasing has a noun wedged in *and* no "say" to anchor on, so codes needed a rule of
  their own.

- **D-61 · Recognised text is bounded on screen, and it took a hang to learn why.**
  Reading a two-page CV out of a PDF **hung the app** on device on 2026-08-15. iOS killed it:
  `WatchdogEvent: scene-update`, *"exhausted real (wall clock) time allowance of 10.00
  seconds"*, main thread inside `TransitionHelper.update()`.

  The diagnosis is worth keeping because the obvious suspect was innocent. The report showed
  **no PDFKit, Vision, model or Speech work on any thread**, and only 41 frames on the main
  thread — so it was neither slow parsing nor runaway recursion. `SWIFT_VERSION = 6.0` with no
  `NonisolatedNonsendingByDefault`, so `PDFReader.text` runs on the generic executor and was
  never on the main thread at all. **The parse was fine; the view was the fault.**

  Root cause: `present(scanned:)` put the *entire* recognised text into one `Text` carrying
  `.fixedSize(horizontal: false, vertical: true)`, which by definition cannot truncate and
  must measure every character. That was survivable while the only source was a photographed
  page. A PDF's text layer is a different order of magnitude — **a two-page CV is 5,400
  characters and an eight-page document 21,600** — and measuring that inside a running
  transition blew the ten-second budget.

  Now capped at 1,200 characters with a count of what is not shown. D-44's guarantee survives:
  it was that a summary can be *checked* against its source, not that every character is
  rendered — and verification and the model prompt both still run against the **full** text.
  A view that hangs the app guarantees nothing.

  **The lesson generalises beyond this bug.** Any view that renders model or document output
  needs a bound, because the length of that output is not something the app chooses. Adding a
  new *source* of text silently changed the size of the text, and nothing in the type system
  or the compiler had an opinion about it.

  `Core/Deadline.swift` was added alongside as defence in depth — `readFile` was the one long
  operation added without a deadline while all its siblings had one. It is not the fix; the
  cap is. `LanguageEngine.bounded` remains its own private copy, deliberately unrefactored
  mid-bugfix.

- **D-62 · Stage 7 — auto-stop, a context meter, and a Siri card.**

  **`SpeechDetector` is in, and its off-switch is a true revert.** With `autoStop` off the
  analyser is built with `[transcriber]` — byte-for-byte the graph Sessions 2–7 verified,
  not a variant of it. This is the most crash-prone file in the project, both runtime traps
  came from it, and a new module in the capture graph deserves a way back that is not "hope
  the new code is right". Release-to-send still works and still wins, since `stopListening`
  guards on `.listening` and whichever fires second is a no-op — so a detector that never
  reports degrades to exactly the old behaviour rather than to a broken one.

  Two tasks, not one. The detector's results arrive as ranges at a cadence this code does not
  control, so timing a silence off that cadence would make the threshold depend on how often
  the framework happens to report. The detector therefore only records **when speech last
  happened**, and a separate 200 ms clock decides when 1.5 s has passed. `lastSpeechAt`
  starting nil is deliberate: until he has said something there is no silence to measure, so
  holding the orb in a quiet room never fires.

  **The context meter is an instrument, not a feature — and it exists to retire open issue 5.**
  D-18's overflow recovery has never been observed running, and the reason it stayed
  unverified is that nobody could see how close a conversation was to the limit. Now it is a
  number. `tokenCount(for:)` and `contextSize` live on **`SystemLanguageModel`, not
  `LanguageModelSession`** — which reads backwards, since a context window is a property of a
  conversation, and putting them on the session was the natural guess that does not compile.
  Both are **iOS 26.4+** against a 26.0 deployment target, so they are `#available`-guarded
  and the section hides itself rather than showing an empty meter.

  **Interactive snippets** turn Siri's grey bubble into a FRIDAY-coloured card. It is a
  separate `SnippetIntent` rather than an inline view because that is how iOS 26 models it —
  the system re-runs the snippet intent to refresh the card, so everything drawn has to be
  reproducible from its parameters. `.result(view:)` lives in the `_AppIntents_SwiftUI`
  overlay, so the file needs `import SwiftUI` alongside `import AppIntents`. The card is
  deliberately plain and `lineLimit(8)`: it is laid out by another process, the ambient field
  and `.glassEffect` both assume a full screen behind them, and D-61 applies to any view
  rendering text this app did not choose the length of.

- **D-63 · Stage 8 — the redesign, organised around what may not move.**

  The problem was measured, not felt: `ContentView` was **721 lines**, **seven** views
  competed for one vertical slot, and the whole app had **three** discoverable controls. The
  third is the one that mattered — sixteen capabilities reachable only by a phrase you
  already knew. The app had got far more capable and no more usable.

  **The organising rule is D-50 turned into a design principle: at rest, nothing moves.**
  Glass re-samples whatever animates beneath it, which is how idle CPU went 8% → 2%. So
  morphing happens only on transitions and direct interaction. That is also in character —
  a composed assistant does not fidget.

  - **`ActionSlot`** replaces four sibling confirm cards and the error banner with one slot
    carrying a `glassEffectID`, so the shape persists and its contents morph. Precedence is
    fixed and documented (**error → call → link → reminder → event**) rather than
    most-recent-wins: two staged actions at once is rare, and a rule you can read beats a
    timestamp you cannot. An error sorts first because it is the only one that is *blocking*
    rather than offered.
  - **`InputBar`'s action row** is the discoverability fix, and the most valuable part of the
    stage. Camera, code and files raise exactly what `Router` raises — a button and a phrase
    are two routes to one place, not two implementations. **Translate pre-fills the phrase
    instead of acting**, because its wording is worth teaching: press it once and you know
    how to ask aloud thereafter.
  - **`CapabilitiesSheet`** lists all sixteen with the words that invoke them. With
    keyword routing, a capability exists exactly as far as someone knows how to ask for it,
    so the phrasing *is* the interface and hiding it was the bug.
  - **`ConversationTurn.kind`** distinguishes `.speech` from `.quoted`. Recognised text used
    to render identically to FRIDAY talking, which was wrong twice: it is not her voice, and
    since D-61 it may be a truncated excerpt.

  `ContentView` is **329 lines**, from 721. The spec said under 300 and that was missed by 29
  — the remainder is the declarative body and five picker/sheet modifiers, which belong at
  the composition root. Recorded rather than papered over.

  **Outstanding acceptance criterion: Release idle CPU.** A Release build is installed and the
  number is unmeasured. If the redesign costs D-50's 2%, the stage is not done — that is the
  criterion that can fail it, and it is owner-measured because it needs Xcode's gauge.

- **D-64 · The orb is the hero of the empty state, and suggestions replace the `+`.**

  Stage 8's redesign was structural, and the owner's response to a screenshot was fair: *"it
  looks the same."* It did. Three of its five changes are invisible until something is
  happening, so the screen the app is looked at in most was the one that changed least.
  Recorded because the lesson is not about glass — **a constraint that forbids motion at rest
  will, left alone, produce a redesign you cannot see.**

  Two things changed, chosen from three mocked-up directions:

  - **The orb moved up and grew to 168pt as the empty state's focal point.** It is the one
    element that *is* FRIDAY rather than a control, and it had been sitting below a text field
    competing with it. It travels via `matchedGeometryEffect` rather than being replaced,
    because an object that moves reads as the same object; one that vanishes and reappears
    does not. `TravellingOrb` applies the effect conditionally through a `ViewModifier`, since
    an inline `if let` yields two different view types and breaks the identity the effect
    exists to preserve.
  - **Five suggestion chips** fill what was ~55% dead space. This supersedes the action row's
    role as the discoverability fix: a chip shows the phrase **and runs it**, so one tap
    teaches the words for next time, where the `+` still required knowing to press it. The
    `+` remains, but as the way to the camera actions rather than as the answer to *"what can
    this thing do"*.

  `FlowLayout` is a `Layout` conformance rather than a `LazyVGrid`, because equal columns
  stretch "Read this" to the width of "How many steps have I done" and the set stops reading
  as phrases and starts reading as a form.

  **The animation budget is one spring**, firing exactly twice in a conversation's life — when
  the first turn arrives and the orb travels down, and if the transcript is ever cleared.
  Nothing added here runs at rest, so D-50 holds by construction rather than by hope.

  **Still unmeasured: Release idle CPU.** The hero puts the orb in the ambient field's
  brightest region, which is precisely where glass re-sampling was expensive at 8%.

- **D-65 · Every long path is bounded, including the one that was not.** Routed tool lookups
  ran with **no deadline** while chat, PDFs and extraction all had one. That was invisible
  until a device screenshot showed *"how many steps have I done"* sitting on **Thinking…**

  A tool has no timeout of its own. `CMPedometer`, `EKEventStore` and `CNContactStore` all sit
  behind callbacks that are **not obliged to fire**, and the first motion query raises a
  permission prompt whose handler may never arrive. An unresumed continuation is not
  cancellable, so the turn strands in `.thinking` and the talk button's `state == .idle` guard
  makes the app unusable until relaunch. **HANDOVER §7's dead app, reached by a new road** —
  and the general lesson is that "everything is bounded" has to be checked against the code,
  not remembered.

  Bounded at twelve seconds: a lookup that takes longer has failed, whatever it says it is
  doing.

- **D-66 · Stage 9a — timers, reckoning, clipboard.**

  **Duplicate calendar events**, fixed alongside. Subscribed calendars overlap and EventKit
  reports each copy separately because to it they *are* separate — a public holiday carried by
  four calendars read back as "Independence Day, all day" four times. Deduplicated on what a
  person would call the same event: same title, same start.

  **`ReckonTool` is D-44 at its cleanest.** A ~3B model asked "what's 15% of 4,200" answers
  confidently and is under no obligation to be right; `NSExpression` either evaluates or it
  does not, and the model never sees the question. Two things worth keeping:
  `NSExpression` **throws Objective-C exceptions** on malformed input rather than returning
  nil, which Swift cannot catch — so input is validated to digits and operators *before* it is
  handed over, and that check is the safety rather than a nicety. And a conversion checks that
  both units are the same `Dimension`, because kilograms into kilometres is a category error
  that `Measurement` would happily produce a number for.

  Every reckoning branch requires a **digit** as well as its keyword, which is what keeps
  "what percentage of people agree" and "how far is the moon" out.

  **A timer is a local notification, not a countdown**, because that is the only design that
  survives being backgrounded — which is where a phone spends most of its life. It reuses the
  notifier reminders already have, so it cost about forty lines.

  Routing truth table is now **81 cases**.


- **D-67 · Stage 9b — the screenshot offer and business cards.**

  **The screenshot offer needs no permission, and that is the design.**
  `userDidTakeScreenshotNotification` tells the app a screenshot happened but
  **never hands over the image**. Reaching into PhotoKit for "the most recent one" would need
  photo-library access *and* would amount to reading his screen without being asked — so
  FRIDAY **offers**, and the picker he chooses from is `PhotosPicker` filtered to
  `PHPickerFilter.screenshots`, which runs out of process. The app still never gains photo
  access and still only ever receives the one image he picked.

  **`CardReader` is the third document type on the same shape**, and by now the shape is the
  point rather than any one document. But the stakes differ: a receipt is read aloud and
  forgotten, while **a card is written into the address book**, where a wrong digit becomes a
  person you can never reach and will not know you cannot reach. So verification is stricter —
  a name that cannot be found is **fatal**, not blanked, because a card whose name the model
  invented is a fabricated person about to be saved to the phone. Its normaliser strips the
  punctuation people scatter through phone numbers, so "+91 98200 33333" matches
  "+919820033333" while a single changed digit still fails. Tested, including that case.

  The write goes through `CNSaveRequest` and is reachable **only from the Save button** — D-34,
  extended from reminders and calendar to contacts.

  **Still not built from stage 9's design: live translation mode, the share extension, and the
  Home Screen widget.** The share extension is the one with a real obstacle rather than just
  cost — an extension hands data to its host app through an **App Group**, which is paid-gated
  (D-52), so it would have to be entirely self-contained and duplicate the reading path into a
  second target. The widget's blocker is smaller but unverified: whether a widget extension
  inherits the app's EventKit and CoreMotion authorisation. **Check that before building it**,
  or the feature dies after the work is done.

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

### D-09 is CLOSED — SpeechDetector adopted

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
8. **Extraction fails *quietly*.** Receipts and boarding passes fall back to the ordinary
   summary whenever a gate declines, which is the safe direction and also means they can stop
   working without looking broken. If extraction stops firing, compare the extracted field
   against the `TextScanner` transcript — the likeliest cause is the model reformatting a
   value rather than copying it.
9. **Superseded — kept for the measurement.** Hindi conversational support. Measured
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
