# Stage 8 — Liquid Glass redesign

**Date:** 2026-08-15 · **Status:** approved by owner · **Depends on:** stages 1–7

A structural redesign of the interface. Not a reskin: the visual language stays, the bones
change.

---

## What is actually wrong

Measured rather than felt:

| | |
|---|---|
| `ContentView.swift` | **721 lines**, the largest file in the project |
| Views competing for one vertical slot | **7** — asset strip, live transcript, four confirm cards, error banner |
| Discoverable controls in the whole app | **3** — gear, send arrow, orb |

The third is the real problem. Sixteen capabilities are reachable only by typing or saying a
phrase you already know. Nothing on screen suggests that "read this", "call mom" or "how do
you say X in French" exist. **The app got a great deal more capable and no more usable.**

## The organising constraint

**At rest, nothing moves.**

Liquid Glass re-samples whatever animates beneath it, which is how D-50 took Release idle CPU
from 8% to 2%. So morphing is used *only* on state transitions and direct interaction, and
never at idle. This is also in character: a composed assistant does not fidget.

Every animation added here must satisfy `motion-meaning` — it expresses a cause and its
effect — rather than being decoration.

## Acceptance criteria

1. **Release idle CPU re-measured and still under 5%.** If the redesign costs the 2%, it is
   not done. This is the criterion that can fail the whole stage.
2. `ContentView.swift` under 300 lines.
3. At most **one** action card on screen at a time.
4. Every capability reachable without knowing a phrase in advance.
5. Zero warnings, and the 65-case routing table still passing.

---

## 8.1 — One pending-action slot

Four confirm cards and the error banner become a single slot. The engine exposes what is
pending; the view renders whichever it is, and switching between kinds **morphs** via
`glassEffectID` inside a `GlassEffectContainer` rather than one card leaving and another
arriving.

```swift
enum PendingAction: Equatable {
    case reminder(ReminderService.Pending)
    case event(EventService.Pending)
    case call(ContactService.PendingCall)
    case link(URL)
    case error(String)
}
```

Precedence is fixed and documented rather than most-recent-wins, because two staged actions
at once is rare and a deterministic rule is easier to reason about than a timestamp:
**error → call → link → reminder → event.** An error sits first because it is the only one
that is blocking rather than offered.

This both fixes the seven-way competition and is the natural showcase for glass morphing —
the shape persists and its contents change, which is exactly what `glassEffectID` is for.

## 8.2 — The action row

A leading button in the input bar expands into camera · scan code · files · translate, using
`glassEffectID` so the single button *becomes* the row rather than a row appearing beside it.

**This is the discoverability fix**, and it is the most valuable part of the stage.

- Camera, code and files raise their picker directly — the same engine flags the router sets.
- Translate **pre-fills "How do you say "** into the text field instead of opening anything.
  The others are actions; this one is a phrase, and pre-filling teaches the phrasing rather
  than hiding it behind a button forever.
- Each target is ≥44pt, collapses on send, and carries an `accessibilityLabel`.

## 8.3 — Capabilities sheet

All sixteen capabilities, grouped, each with an example phrase. Reachable from the action row
and from asking "what can you do" — the router already sends that to chat, and it will now
also raise the sheet.

Plain content surface, not glass: it is content, and `GlassSurface.swift` already documents
that glass belongs to the control layer.

## 8.4 — Turn kinds

`ConversationTurn` gains a `kind` — `.speech` or `.quoted`. Recognised document text currently
renders identically to FRIDAY speaking, which is wrong twice over: it is not her voice, and
since D-61 it may be a truncated excerpt.

`.quoted` renders monospaced, muted, with a leading rule and no tone tint. It reads as a
quotation because it is one.

## 8.5 — Splitting `ContentView`

| New file | Takes |
|---|---|
| `UI/StatusHeader.swift` | header, status chip, fault card |
| `UI/InputBar.swift` | text field, send, action row |
| `UI/ActionSlot.swift` | `PendingAction` rendering, `ConfirmCard` |
| `UI/CapabilitiesSheet.swift` | the sheet |
| `UI/ContentView.swift` | composition, scene phase, pickers |

Boundaries are by *responsibility*, not by line count: each takes state it can render from
its inputs alone, so none needs the engine except through what it is handed.

---

## Risks

1. **Idle CPU regression.** The one that can fail the stage. Mitigated by the rest-is-still
   rule, and caught by criterion 1 rather than by hoping.
2. **`glassEffectID` morphing is unfamiliar territory.** It has not been used in this project
   before, and specular highlights do not render correctly in the Simulator — so it can only
   be judged on device.
3. **Reduced Transparency.** Glass degrades to a solid fill when the accessibility setting is
   on. It must be checked, not assumed, and the layout must not depend on translucency to be
   legible.
