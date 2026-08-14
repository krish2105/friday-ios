# FRIDAY — engineering write-up

An on-device iOS voice assistant. Swift 6, iOS 26, no backend, no API keys, no network.
Speech recognition, reasoning and speech synthesis all run on the phone.

This document is about the engineering decisions, not the feature list. The interesting
parts of this project are the things that turned out to be wrong.

---

## The headline

**Half the app keeps working with Apple Intelligence switched off.**

That was not a design goal. It fell out of fixing a bug, and it is the single best summary of
what this project taught me.

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

## 5. Constraints documented rather than worked around

Four things in the spec could not be built as written. None were faked.

| Constraint | Reality |
|---|---|
| Always-on wake word | iOS does not permit persistent background audio capture for third-party wake-word detection. Entry points are push-to-talk, Siri, Control Centre and a Lock Screen widget. |
| *"Hey Siri, ask FRIDAY what time it is"* in one utterance | App Intents allows only `AppEntity`/`AppEnum` parameters in a spoken phrase. An open question is neither. Siri prompts for the question instead. A canned `AppEnum` would buy the one-shot phrasing at the cost of only answering a hardcoded list. |
| Lock Screen widget showing last-brief timestamp | A widget runs in its own process; reading app data needs an App Group, which requires a paid membership and risks breaking provisioning on a free account. It is a launcher instead. |
| WeatherKit | Needs a paid account. The tool is written and unregistered — registering a tool that can never succeed costs schema tokens and adds a hang path. |

Each of these was a decision with a stated trade-off and an expiry condition, not a gap.

---

## 6. Graceful degradation, verified rather than assumed

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

## 7. What I'd do differently

- **Test the failure paths first.** `.error` was a dead end for four sessions — every failure
  permanently killed the talk button — because only the happy path was ever exercised.
- **Instrument before theorising.** Two wrong diagnoses on the layout bug cost more than the
  fix did.
- **Don't add backstops nobody asked for.** A speculative `maximumResponseTokens` cap
  truncated guided generation mid-structure and produced a generic error on turns that were
  otherwise fine. Two of the defects in this project were introduced by my own precautions.

---

## Numbers

| | |
|---|---|
| Swift files / targets | 35 / 2 |
| Idle CPU (Release) | 2% against a 5% budget |
| Memory | ~21 MB |
| Network calls | 0 |
| API cost | £0 |
| Defects found on device | 16, none catchable by the compiler |
