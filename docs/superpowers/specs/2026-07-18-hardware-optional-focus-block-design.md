# Hardware-optional Focus Block

**Date:** 2026-07-18
**Status:** approved, building

## Why

NeuroSync helps founders get focused. Today the Focus Block is headset-only — the start
presets are `.disabled(!model.isConnected)`, the empty state literally says *"Connect a board to
run a focus block,"* and every bit of its value (drift detection, the recap's "min focused") is
computed from the EEG-derived `BrainState`. Rip out the headset and there is nothing.

The owner's direction: **the block must work without a headset.** Make focus accessible on day one,
no hardware required. The headset becomes the *upgrade* that adds the brain layer — not the price of
entry.

## The one rule this must not break

`../CLAUDE.md` Manifesto II — **no fabricated NUMBER reaches a surface.** A single around-ear dry
channel is the only thing that can measure focus (Pope `β/(α+θ)`). With **no headset there is no
brain measurement**, so a headset-free block may show **measured behavioural facts** but **never a
focus score, "minutes focused", or a focus %** — those are brain claims and inventing one is the
exact thing this codebase exists to refuse.

## Design — one block, two tiers

A Focus Block runs in two tiers that stack inside a single block:

- **Tier 1 — headset-free (always on).** A timer + **app-context drift** + a behavioural recap.
  Source = the frontmost-app watcher that already exists (`Context/ActivityWatcher.swift` /
  `AppWatcher`, bundle-id only, no titles/keystrokes).
- **Tier 2 — headset-augmented (when a board is connected).** Everything above **plus** the existing
  EEG layer: Pope brain-drift (`DriftIntervention` on the gated `.daydream` state), minutes of
  measured focus, coverage.

The tiers coexist. A block started with no headset that gains one mid-block simply starts
accumulating brain epochs; a block that loses the headset falls back to behavioural-only. Nothing
about the block *requires* the radio.

### Drift without a brain signal

"Drift" in Tier 1 = **you slipped out of your work app**, measured, never inferred from EEG:

- At `startBlock`, anchor the block to the **effortful** app kind the user is in
  (`ActivityKind.isEffortful` already distinguishes coding/design/reading/meeting/onCall from
  comms/browsing/break/walk/unknown). Optional one-line **intention** string ("Ship the auth flow").
- Each second, sample the frontmost app kind. If it is **non-effortful** continuously past a dwell
  window (`appDriftDwellSec`), fire **one** quiet, debounced nudge — *"back to Xcode?"* — with the
  same anti-nag discipline as the EEG drift (≤ 1 nudge per `debounceSec`).
- Browsing is the acknowledged soft case (docs read like distraction). The conservative dwell + a
  single debounced nudge + non-judgemental copy keep it from nagging the ADHD-founder audience; the
  recap reports slips as neutral facts, never as failure.

### The honesty boundary — two vocabularies that never mix

- **Behavioural (always):** "22 min on task in Xcode · slipped to Slack 3× · longest stretch 14 min."
  Words: **on task**, **slipped**, **stretch**. Measured facts.
- **Brain (only when a headset was connected + gated):** "18 min of measured focus · 91% coverage."
  Words: **focus**, **coverage**. Pope layer.

**"On task" (an app fact) is never "focused" (a brain fact).** In the type system the brain half of
the recap is `Optional`; no headset → it is `nil` → the UI has no focus number to render. A
screenshot of a headset-free block cannot be mistaken for a brain measurement. This mirrors the
synthetic wall: the guarantee lives in the data path, not just the copy.

## Architecture (follows existing patterns)

### `Core/FocusBlock.swift` — extend, stay pure & `nonisolated`
- Keep `DriftIntervention` (EEG brain-drift) unchanged.
- Add **`AppDriftDetector`** — its behavioural mirror. `step(onTask: Bool, dt:) -> Bool`: sustained
  off-task dwell past `appDriftDwellSec`, rate-limited by `debounceSec`; `reset()` on block end. Same
  shape and discipline as `DriftIntervention`, so it is testable with no radio and no clock.
- Add a pure **anchor** helper: given the frontmost `ActivityKind` at start (and/or the dominant
  effortful kind so far), decide the block's work anchor and whether the current app is "on task".
- Split the recap:
  - **`BehaviorRecap`** (always): `totalSeconds`, `onTaskSeconds`, `longestOnTaskStretchSec`,
    `slips` (count), a small top-apps breakdown (kind/label + seconds). **No focus field.**
  - **`BlockRecap.brain: BrainRecap?`** — the existing focused/withheld/coverage/longest-focused
    fields, present **only when brain epochs exist**. `recap(epochs:driftCatches:)` returns `nil`
    brain when there are no trustworthy epochs.
- `FocusBlockConfig` gains `appDriftDwellSec` (default ~30 s) alongside the existing EEG `driftDwellSec`.

### `App/VertexModel.swift` — @MainActor
- The per-second block loop runs on its own timer, **headset-independent** (today it early-returns
  without a connection because it reads `snap.metrics`). Each second:
  - Sample frontmost app → feed `AppDriftDetector` and accumulate the behavioural tally.
  - **If** connected + trustworthy: also build the brain epoch (as today, `effortful: true`) and feed
    the EEG `DriftIntervention`.
  - **One** unified `fireDriftNudge()` fed by *either* source, through **one** debounce — never a
    double nudge. Nudge copy adapts: app-context ("back to Xcode?") vs brain ("drifting").
- `startBlock(minutes:intention:)` drops the `isConnected` requirement and captures the app anchor.
- `endBlock` builds the two-part recap: behavioural from the app tally (always), brain from
  `blockEpochs` (only if any trustworthy epochs exist).

### `UI/MenuBar.swift` + `ContentView.swift`
- Un-gate the presets (remove `.disabled(!model.isConnected)`); empty-state copy leads headset-free
  ("Start a block — NeuroSync keeps you on task, headset or not.").
- The **disconnected main window becomes the block home** (today it is the `NO DEVICE` flat line):
  big glass "Start a focus block" with presets + optional intention; a running-block surface with
  elapsed, on-task app, slip count; "Connect a headset for the brain layer" as a *secondary* invite,
  not a gate. The brain scope/gauge appears only when connected.
- `RecapView` renders the behavioural half always and the brain half only when `recap.brain != nil`.
  A visible line states *why* there is no focus number ("no headset — behaviour only").

## Testing (the invariants are the feature)

Extend `neurosyncTests/FocusBlockTests.swift`. New tests, all radio-free:

1. **`headsetFreeBlockNeverProducesAFocusNumber`** — a block run with no brain epochs yields
   `recap.brain == nil`; the behavioural half is populated. The type makes a focus number
   unrenderable.
2. **`appDriftFiresOnSustainedOffTaskDwell`** — `AppDriftDetector` fires after `appDriftDwellSec`
   off-task, and not before.
3. **`appDriftDebounceHoldsUnderSustainedSlip`** — a long slip produces one nudge per `debounceSec`,
   never a storm (mirror of the existing EEG debounce test).
4. **`onTaskAppNeverFiresDrift`** — staying in the effortful work app never nudges; switching between
   two effortful apps (Xcode → Figma) is not a slip.
5. Keep every existing guarantee green: `noNudgeBehindAClosedGate`, `noNudgeOutsideABlock`, the EEG
   debounce, and `recapNeverCountsWithheldAsFocus`.

Plus the standing invariants: `detachedElectrodeNeverReadsAsHighFocus`,
`menuBarNeverReadsPersistedData`, and the snapshot suite (add a headset-free block-home appearance).

## Scope

- **This PR:** start / run / nudge / recap a block with **no headset**; two-vocabulary recap;
  block-first disconnected home; the tests above.
- **Follow-up (flagged, not now):** persisting headset-free blocks into the **DAY timeline**. The
  `SessionRecord` / Convex schema is brain-epoch-centric; rendering a behavioural-only block there
  needs a schema touch that ripples into cloud sync — its own pass. The **live** recap works
  regardless.

## Non-goals

- No blocklist of "bad apps" — drift is "left an effortful app," using the existing `isEffortful`.
- No self-report check-in prompts (rejected: nags the audience we are protecting).
- No change to the Pope metric, the three gates, the frozen baseline, or the synthetic wall.
