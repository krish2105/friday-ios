# Stage 4 — "She acts"

**Date:** 2026-08-15 · **Status:** approved by owner · **Depends on:** stages 1–3, bilingual

Four features that move FRIDAY from answering questions to doing things. All free on a
Personal Team: two Info.plist usage strings, no entitlement, no capability, nothing that
touches provisioning.

---

## Why these four

FRIDAY currently answers. She does not act. The gap is most obvious in reminders: she stages
one, a button writes it to Apple Reminders, and then *the Reminders app* nudges you. FRIDAY
never speaks again. Stage 4 closes that loop and adds the three lookups a daily driver is
expected to have.

## Invariants

Every feature obeys the decisions already in force. These are not restated per-feature below.

| # | Rule | Source |
|---|---|---|
| 1 | Routing is decided in Swift, never by the model | D-43 |
| 2 | Facts — numbers, names, dates — are composed in Swift | D-44 |
| 3 | Anything consequential stages first and needs a real press | D-34 |
| 4 | Nothing persists beyond the session | owner, 2026-08-15 |
| 5 | Every new spoken line goes through `FridayEngine.voiced` | D-56 |
| 6 | No capability requiring a paid account | D-32 |

Rule 5 is the one most easily forgotten: this stage adds roughly thirty new strings, and each
must work in Hindi as well as English.

## New Info.plist keys

Both are usage strings. Neither is a capability.

- `NSContactsUsageDescription` — "FRIDAY looks up numbers and birthdays when you ask. Contacts are read on-device and never leave your phone."
- `NSMotionUsageDescription` — "FRIDAY reads your step count when you ask how far you've walked."

---

## 4.1 — FRIDAY nudges you herself

**Problem.** A confirmed reminder is written to Apple Reminders with an `EKAlarm`. The nudge
comes from Reminders, in the system's voice, with no trace of FRIDAY.

**Design.** On confirm, additionally schedule a `UNCalendarNotificationTrigger` whose body is
written in FRIDAY's register. Local notifications only — **no push entitlement is involved**,
which is what makes this free.

**Owner decision: a Settings toggle.** Because both nudging is redundant and neither nudging
is worse, who alerts is a preference:

| Toggle | Behaviour |
|---|---|
| On (default) | FRIDAY schedules the notification; the `EKReminder` is saved **without** an `EKAlarm`, so Reminders stays quiet. One nudge, and it is hers. |
| Off | Exactly today's behaviour — `EKAlarm` is added, FRIDAY schedules nothing. |

The `EKReminder` is written either way. D-34's "a real press writes to a real store" holds,
and the reminder survives the app being deleted.

**Notification actions** (owner decision): `Done` and `Snooze 10m`, via a
`UNNotificationCategory`. Done clears it; Snooze re-schedules ten minutes out. Both are
handled without opening the app.

**Failure.** Authorisation is requested on the first confirm, not at launch — the same
just-in-time pattern as the microphone. Denied means FRIDAY says so, names Settings, and
falls back to writing the `EKAlarm` so the reminder still fires from somewhere.

**New:** `FRIDAY/Notify/FridayNotifier.swift`. Touches `ReminderService.confirm`,
`SettingsView`, `FRIDAYApp` (delegate registration for actions).

## 4.2 — Contacts

**Routing.** `Intent.contact(name:aspect:)`, matched in Swift. Aspects: `number`, `email`,
`birthday`, `nextBirthday`.

Needles are demonstrative-free but noun-anchored, in the style `Router` already uses:
"what's ‹name›'s number", "call ‹name›", "‹name›'s birthday", "whose birthday is next".

**Owner decision: name matching covers names, nicknames and relationships.** "Mom" is rarely
how a contact is filed. `ContactStore` matches, in order:

1. the given/family/organisation name
2. `CNContactNicknameKey`
3. `CNContactRelationsKey` on **any** contact whose relation label matches the spoken word
4. relations on the user's own "me" card — where iOS actually stores "mother"

Ambiguity is resolved by asking, never by guessing: two matches for "raj" gets "I've got two
Rajs, boss — Raj Malhotra or Raj Verma?"

**Owner decision: calling is staged, never dialled.** She reads the number and offers a Call
button, which opens `tel:`. `Router` has known phrasing gaps; a false positive that dials a
real person at 2am is not an acceptable failure. This mirrors D-34 exactly.

**Privacy.** Read-only. No contact is ever put in a model prompt — the name is matched in
Swift and the answer is composed in Swift, so the ~3B model never sees anyone's number.

**New:** `FRIDAY/Tools/ContactTool.swift`, `FRIDAY/Core/ContactService.swift` (staging, mirrors
`ReminderService`).

## 4.3 — Create calendar events

**Problem.** `CalendarTool` reads. Nothing writes.

**Design.** `EventService` mirroring `ReminderService` precisely — stage, cancel, confirm —
so the confirmation card, the Hindi path and D-34 all work identically with no new concepts.

**Routing.** `Intent.event(title:when:)` — "put ‹x› in my calendar", "schedule ‹x› at ‹y›",
"add a meeting ‹...›". Checked **before** the calendar-read needles, because "schedule" appears
in both and the read is the wrong answer to a write request.

Dates come from `CalendarTool.firstDate(in:)`, already in use. Default duration one hour; an
event with no detectable time is refused rather than guessed — "When should I put that down
for, boss?"

**New:** `FRIDAY/Core/EventService.swift`. Touches `Intent`, `ContentView` (a second
confirmation card, or the existing one generalised).

## 4.4 — Steps, without HealthKit

**Why it matters.** HealthKit is paid-gated (D-32). `CMPedometer` is not. This is the free
route to a feature the account cannot otherwise have, and it is worth writing up as such.

**Design.** `MotionTool` answering steps, distance and flights climbed for today, or a named
day within the last seven — which is `CMPedometer`'s entire history window, so "last month" is
declined honestly rather than answered with a wrong number.

Guarded by `CMPedometer.isStepCountingAvailable()`. Numbers formatted in Swift (rule 2).

**Routing.** Extend `Router.deviceAspect`, or a sibling `motionAspect` — "how many steps",
"how far have I walked", "how many flights". Multi-word needles: a bare "steps" would catch
"what are the next steps".

**New:** `FRIDAY/Tools/MotionTool.swift`.

---

## Testing

Swift-side logic is testable on the Mac the way `Router`, `Bilingual` and `ReceiptReader`
already are, and that is where the truth tables go:

- routing truth table extended to cover all four features **and** re-run against every
  existing case, since four new needle groups is the most likely regression in the project
- contact name matching, including the ambiguous-match path, against a fixture set
- pedometer window arithmetic — "eight days ago" must decline

Device verification is the owner's, and cannot be skipped: three new permission prompts, a
notification that fires at a real time, and a real phone call button.

## Risks

1. **Router regressions.** Four new needle groups is the largest single addition to `Router`
   so far. Mitigation: the truth table runs every existing case, not just the new ones.
2. **Notification authorisation is asked at reminder-confirm time**, which is a moment the
   user is already committing to something. If that reads as intrusive, move it to Settings.
3. **`CMPedometer` returns nothing on a device that was not carried.** Zero steps and no data
   are different states and must not both say "zero, boss".
