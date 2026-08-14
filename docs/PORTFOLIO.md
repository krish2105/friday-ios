# FRIDAY — engineering write-up

An on-device iOS voice assistant. Swift 6, iOS 26, no backend, no API keys, no network.
Speech recognition, reasoning and speech synthesis all run on the phone.

This document is about the engineering decisions, not the feature list. The interesting
parts of this project are the things that turned out to be wrong.

---

## The headline

**Half the app keeps working with Apple Intelligence switched off.**

That was not a design goal. It fell out of fixing a bug, and it is the single best summary of
what this project taught me: the useful parts of an "AI app" are usually the parts that are
not the model.

The same idea shows up again in structured extraction, where the model is allowed to *choose*
a value but never to *assert* one — Swift checks every field against the page before FRIDAY
says it out loud.

---

## 1. A zero-warning strict-concurrency build proved almost nothing

Roughly 2,600 lines were written against the iOS 26 SDK before anyone could compile them.
Getting to a clean build under `SWIFT_STRICT_CONCURRENCY = complete` took five compile errors
and eleven warnings. That felt like the hard part. It wasn't.

Two crashes then appeared on the device that the compiler **cannot** catch:

```
_dispatch_assert_queue_fail
_swift_task_checkIsolatedSwift
closure #1 in closure #1 in static SpeechInput.requestRecognitionAccess()
TCC __TCCAccessRequest_block_invoke_8
```

`SpeechInput` is `@MainActor`, so its static method was main-actor isolated, and the
`SFSpeechRecognizer.requestAuthorization` completion handler **inherited that isolation**.
TCC invokes that handler on its own background XPC queue. Swift 6's runtime checks the
executor, finds a mismatch, and traps.

The same fault appeared again in the audio tap, because `AVAudioNodeTapBlock` is not
`NS_SWIFT_SENDABLE` and `AVAudioEngine` calls it on the realtime audio queue.

**Why the compiler can't see it:** isolation inheritance through a non-`Sendable` closure
parameter is legal at compile time. It only fails when the system calls back from somewhere
else. Static analysis genuinely cannot know which queue Apple's framework will use.

The fix is one keyword in each case — `nonisolated` and `@Sendable`. Finding them took
reading the actual crash reports off the device.

**What I'd say in an interview:** strict concurrency is a floor, not a ceiling. It proves the
code is internally consistent. It says nothing about the isolation contract of every
framework callback you hand a closure to.

---

## 2. The 3B model could not route tools, so routing moved into Swift

The original design followed Apple's `Tool` protocol: register tools, let the model decide
when to call them. On device, with five tools registered, the model:

- answered *"what can you do"* with the battery level
- sent *"what time is it"* to the reminder tool
- staged a reminder titled *"What time is it?"*
- wedged turns on a weather tool that cannot work on a free account

Three rounds of tightening tool descriptions and persona rules did not fix it. Tool selection
is not something a ~3B model does reliably with several tools in play.

**So routing stopped being the model's job.** `Core/Intent.swift` matches intent in Swift,
calls the tool directly, and composes the sentence in code. The model keeps the one thing it
is genuinely good at — phrasing a conversational reply.

Three consequences, in increasing order of interest:

1. **Mis-routing became impossible**, not merely less likely. A tool cannot fire on a turn
   that was not routed to it.
2. **Numbers cannot be paraphrased into different numbers.** Factual sentences are built in
   Swift. A small model rewording "80%" into "about 85%" is the worst failure an assistant
   has, and it is now structurally unreachable.
3. **The session registers no tools at all**, so the persona and conversation own the entire
   ~4,096 token budget four schemas used to share.

And the consequence nobody planned: with routing in Swift, **the utility features stopped
depending on the model**. With Apple Intelligence disabled, "what time is it" still answers
correctly. Only conversation degrades.

**The trade-off, stated honestly:** keyword routing has gaps. Unanticipated phrasings fall
through to chat. That is a deliberate choice — predictable and wrong in obvious ways beats
unpredictable and wrong in surprising ways.

---

## 3. Measure, don't reason

The UI was clipped at both edges on device. I produced two confident, well-argued diagnoses.

**Both were wrong.** The first blamed the header being too wide — disproved when
`minimumScaleFactor` didn't help, since text would have shrunk rather than clipped. The
second blamed the ambient background's oversized frame — but a 402pt view centred inside a
470pt parent still lands centred, so that shouldn't clip either.

One `onGeometryChange` printing the container width settled it in a single pass:

```
outer 470 · content 470      (on a 402pt screen)
```

`AmbientBackground` was a `ZStack` sibling. A `ZStack` sizes to its largest child, and its
gradient blobs have fixed 470pt frames. Moving it to `.background` — which is proposed the
primary view's size and can never grow it — fixed it structurally.

**The lesson wasn't the bug.** It was that when a hypothesis fails, the next move is to
instrument, not to form a second hypothesis. I spent two build cycles reasoning when one
measurement was available the whole time.

---

## 4. Liquid Glass re-samples everything animating beneath it

Idle CPU had a stated budget of under 5%. A Release build measured **8%**.

An earlier decision had already identified `Canvas` + `TimelineView` as the enemy — around
30% CPU — and correctly removed it from the idle path. That decision was right, and
implemented correctly. It was also **incomplete**, because it budgeted the orb in isolation.

Three continuous animations actually ran on the idle screen: the orb's resting pulse, the
ambient field's drifting gradients, and a status dot animating `shadow(radius:)`. And three
Liquid Glass surfaces sat on top of all of it — glass re-samples its backdrop every frame, so
anything moving underneath means a blur that can never be cached.

```
8%  →  6%   ambient field holds still at rest
6%  →  2%   resting orb frozen; status shadow made static
```

**2% in Release, energy impact High → Low.**

The last step contradicts the spec, which asks for an idle breathing pulse. That was an
explicit trade: keep the interactive glass, lose the resting animation. Motion now belongs to
the active states, where the cost is expected and the user is watching.

---

## 5. The model selects; Swift verifies

Reading a receipt means asking a ~3B model to read **money off a photograph**, which is the
paraphrasing risk above with the stakes raised. Guided generation returns a typed `Receipt`
rather than a string that needs parsing — but **typed is not true**. The fields are still
whatever the model produced.

So the model's job was reduced from *composition* to *selection*. Every `@Guide` asks for the
value **copied exactly as printed**, which turns each field into a claim about the page that
code can check:

```swift
guard !total.isEmpty, isTheTotal(total, in: text) else { return nil }
```

Verification is the feature; extraction is the easy part. Three gates, and any of them
declining costs only an ordinary summary: Swift decides it looks like a receipt at all, the
model picks the fields, and Swift refuses anything it cannot find on the page.

**The check that matters most is narrower than it first looks.** Searching the whole page
proves only that a number was printed *somewhere* — so the tax line, the subtotal, the bill
number and the card digits would all have passed. The total has to appear on a line that
*says* it is the total:

| Model returns | Result |
|---|---|
| `Rs 1,240.00` — correct | spoken |
| `Rs 1,420.00` — transposed | rejected |
| `1043.50` — the subtotal | rejected |
| `93.92` — a GST line | rejected |
| `4471` — the bill number | rejected |

Merchant and date are *blanked* rather than rejected when unverifiable — a receipt without a
merchant is still worth saying, a receipt with the wrong number is worse than none.

The pattern generalised: a boarding-pass reader is the same forty lines in a different hat.
That shape — cheap deterministic gate, model selects, code verifies — is what was worth
building, not the receipt specifics.

---

## 6. Greedy decoding is deterministic, and that is the problem

*"What languages do you know"* answered with the same run of language names over and over —
Marathi, Nepali, Urdu, Hindi, Bengali, Telugu, Marathi, Tamil… — until a 20-second deadline
killed it and FRIDAY said *"that one's taking too long, boss"* about a turn that was working
exactly as instructed.

Two earlier decisions combined into this. Sampling was set to `.greedy`, which takes the
argmax at every step, so once the model enters a repetition cycle it re-picks the same tokens
**forever**. And `maximumResponseTokens` had been deliberately removed, so nothing bounded it.

**The interesting part is that the obvious fix was exactly wrong.** The deadline fired on a
turn that was actively producing tokens, so the natural response — make it an *inactivity*
timeout — would have hung the app instead of erroring. An active loop never goes inactive.
Reading the symptom mattered more than fixing the timer.

The real fix was two layers. Sampling became `.random(top: 3, seed: 1)`: the `seed` parameter
delivers the reproducibility greedy was chosen for in the first place, while top-3 keeps the
model near the argmax it would have taken anyway, and cycles break because the RNG state has
advanced by the time a repeated context comes round again. And because no sampling mode is
*guaranteed* loop-free, a Swift-side guard cuts the stream when a sixty-character window
repeats — salvaging the text from before the repeat, which on the real 5,846-character runaway
is a perfectly good list of languages.

The original reason for greedy had also quietly expired. It was chosen because random sampling
answered *"what time is it"* with *"what's for dinner"* — a failure that became **structurally
impossible** once routing moved into Swift, since time never reaches the model at all.

---

## 7. Adding a source of text silently changed the size of the text

Reading a two-page CV out of a PDF hung the app. iOS killed it:

```
WatchdogEvent: scene-update
"exhausted real (wall clock) time allowance of 10.00 seconds"
main thread → TransitionHelper.update()
```

Every plausible suspect was innocent. The report showed **no PDFKit, Vision, model or Speech
work on any thread**, and only 41 frames on the main thread — so neither slow parsing nor
runaway recursion. `SWIFT_VERSION = 6.0` without `NonisolatedNonsendingByDefault` means a
`nonisolated async` function runs on the generic executor, so the PDF was never parsed on the
main thread at all.

**The parse was fine. The view was the fault.** Recognised text went into a single `Text`
carrying `.fixedSize(horizontal: false, vertical: true)` — which by definition cannot truncate
and must measure every character. That was survivable while the only source was a photographed
page. A PDF text layer is a different order of magnitude:

| Source | Characters |
|---|---|
| Photographed page | ~1,500 |
| Two-page CV | ~5,400 |
| Eight-page PDF | ~21,600 |

The lesson generalises past the bug: **any view rendering model or document output needs a
bound, because its length is not something the app chooses.** Adding a new *source* changed
the *size*, and neither the type system nor a zero-warning strict-concurrency build had an
opinion about it.

---

## 8. Measuring beats remembering, including about frameworks

Four claims got checked rather than assumed, and three of them were false.

**"iOS 26.4 gave Foundation Models vision."** Widely written up. `Transcript.Segment` in
`iPhoneOS26.5.sdk` has exactly two cases, `.text` and `.structure`. There is no image segment;
the model cannot see a photograph, and OCR remains the only route from image to model.

**"App Groups is available to free teams."** Apple's own capability table says so. Xcode's
free-team provisioning refuses the entitlement and the build fails at sign time. The table
describes portal tiers, not what will actually sign.

**"`NLLanguageRecognizer` can spot romanised Hindi."** It cannot, and it is *confidently*
wrong — *"kya haal hai boss"* reads as Dutch, *"mujhe kal subah yaad dilana"* as Indonesian at
1.00. A planned feature was dropped on the strength of one probe; wiring it in would have sent
ordinary English turns through two translation hops on the strength of noise.

**"`tokenCount` is on `LanguageModelSession`."** It is on `SystemLanguageModel`, which reads
backwards, since a context window is a property of a conversation.

And one where the docs were wrong in the other direction: VisionKit's `apinotes` rename
`didFailWithError:` to a shorter Swift name. The compiler wants the unabbreviated one — and
because the protocol requirement is *optional*, the short form only **warns**, so a scanner
failure would have had no handler at all.

**What I'd say in an interview:** every seam I checked was cheap to check and several were not
what the documentation said. The habit that paid was treating the SDK as the authority and the
compiler as the authority over that.

---

## 9. Constraints documented rather than worked around

Four things in the spec could not be built as written. None were faked.

| Constraint | Reality |
|---|---|
| Always-on wake word | iOS does not permit persistent background audio capture for third-party wake-word detection. Entry points are push-to-talk, Siri, Control Centre and a Lock Screen widget. |
| *"Hey Siri, ask FRIDAY what time it is"* in one utterance | App Intents allows only `AppEntity`/`AppEnum` parameters in a spoken phrase. An open question is neither. Siri prompts for the question instead. A canned `AppEnum` would buy the one-shot phrasing at the cost of only answering a hardcoded list. |
| Lock Screen widget showing last-brief timestamp | A widget runs in its own process; reading app data needs an App Group, which requires a paid membership and risks breaking provisioning on a free account. It is a launcher instead. |
| WeatherKit | Needs a paid account. The tool is written and unregistered — registering a tool that can never succeed costs schema tokens and adds a hang path. |
| Hindi spoken to FRIDAY | `SpeechTranscriber` supports 30 locales and none is Hindi. Not a poor one — none. Hindi is typed; translation wraps an English model on both sides, because the language model has no Hindi either. |
| HealthKit for step counts | Paid-gated like the rest. `CMPedometer` needs only a usage string and answers the question people actually ask, so the feature exists by a different route rather than not at all. |

Each of these was a decision with a stated trade-off and an expiry condition, not a gap.

---

## 10. Graceful degradation, verified rather than assumed

Every failure mode was tested on the device, including by forcing branches that cannot occur
naturally:

- **Apple Intelligence off** → red state, correct fix instruction, Swift-routed tools keep working
- **Microphone denied** → in-character banner, app remains usable
- **Calendar denied** → reported calmly, no crash
- **Speech assets fail** → forced in a temporary build; banner shown, state recovers
- **Airplane mode** → transcription unaffected; it never used the network
- **Phone call mid-transcription** → stops cleanly, returns to idle
- **A hung turn** → 20-second deadline, because a wedged `.thinking` state made the app
  unusable until relaunch

That last one is worth expanding. The first fix used `withThrowingTaskGroup` — which
**awaits every child before returning**, so a model wedged on an unresumed
`withCheckedContinuation` kept the group waiting forever. The deadline could never fire.
Cancellation doesn't help either: an unresumed continuation is not cancellable. The working
version abandons the losing side instead. A stranded task is a small leak; a stranded
`.thinking` is a dead app.

---

## 11. What I'd do differently

- **Test the failure paths first.** `.error` was a dead end for four sessions — every failure
  permanently killed the talk button — because only the happy path was ever exercised.
- **Instrument before theorising.** Two wrong diagnoses on the layout bug cost more than the
  fix did.
- **Don't add backstops nobody asked for.** A speculative `maximumResponseTokens` cap
  truncated guided generation mid-structure and produced a generic error on turns that were
  otherwise fine. Two of the defects in this project were introduced by my own precautions.
- **Bound anything whose length you don't choose.** Model output, OCR text, a PDF's text
  layer. The PDF hang was not a hard bug — it was an unbounded view meeting an input an order
  of magnitude larger than the one it was written against.
- **Read the symptom before fixing the mechanism.** The repetition loop looked like a timeout
  problem, and the intuitive fix — an inactivity deadline — would have turned an error into a
  hang. The deadline was never at fault.
- **Make the escape hatch a true revert.** `SpeechDetector` sits behind a toggle whose *off*
  position rebuilds the analyser exactly as it was before the detector existed, rather than a
  variant of it. In the one file that produced every runtime crash in this project, "hope the
  new code is right" is not a rollback plan.

---

## Numbers

| | |
|---|---|
| Swift files / targets | 51 / 2 |
| Idle CPU (Release) | 2% against a 5% budget |
| Memory | ~21 MB |
| Network calls | 0 |
| API cost | £0 |
| Routing cases under test | 65, re-run on every change |
| Defects found on device | 18, none catchable by the compiler |
