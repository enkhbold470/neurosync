# NeuroSync — The Day view

**Date:** 2026-07-14
**Status:** approved (design), pending implementation

A second surface for NeuroSync: a persisted, annotated **day timeline** that puts measured brain
state next to what you were actually doing — calendar meetings, on-call blocks, Claude coding,
design sessions, breaks, walks — and says plainly where focus fell apart.

The live instrument (`LIVE`) is unchanged and remains the app's primary claim. The Day view
(`DAY`) is a second tab over the same data.

---

## The integrity constraints this design is shaped by

`CLAUDE.md` (this repo) and `../CLAUDE.md` (workspace) are binding. Four of their rules directly
shape this feature, and each one is answered here:

1. **"No simulations dressed as data."** Synthetic sessions exist, but they are *hard-walled and
   watermarked* — see [Synthetic days](#synthetic-days). They cannot reach the menu bar, the live
   gauge, or any aggregate that mixes with real data.
2. **"Don't oversell the score."** Stress and anxiety are **not measured**. They are self-reported
   markers. The only measured channels are Focus, Calm, and Clench.
3. **"Analysis prints association, never causation."** Every finding carries its confound line.
4. **"The number is not comparable between people, and only within a session."** The baseline stays
   per-session and frozen; the Day view never compares raw scores across days without saying so.

A fifth constraint comes from the hardware itself: **frontal midline theta (FMθ) — the best-validated
cognitive-effort marker in the literature — requires Fz, and an around-ear pad physically cannot
reach frontal midline.** Panels that would need FMθ are labelled as proxies built from what v4 *can*
see, never as the literature metric.

---

## Measured channels

Three, all derivable from one around-ear channel, all already in or adjacent to `Core/DSP.swift`:

| Channel | Definition | Honest status |
|---|---|---|
| **Focus** | Pope engagement `β/(α+θ)`, logistic-mapped against the frozen per-session baseline | Real. Already implemented, already gated. |
| **Calm** | α share of `θ+α+β` | Real. A relaxation cue, not `100 − focus`. Already implemented. |
| **Clench** | γ share (30–45 Hz) of total band power, normalised against the calibration-window median | Real — as an **artifact indicator**. γ at an earpad is temporalis EMG, not cortical gamma. This is the β-contamination confound made *visible* instead of hidden. |

Clench is the closest thing to a stress tell this hardware can honestly produce, and it is presented
as what it is: *your jaw is tense and the focus number in this window is contaminated*.

## Derived state — including daydream

`Core/BrainState.swift`, pure and `nonisolated`, tested without a radio.

```swift
enum BrainState { case withheld, focused, neutral, daydream, calm, clenched }
```

Resolved per 1 Hz epoch, in this order:

- **`.withheld`** — any gate closed (`!signalOk || !fsOk || calibrating`). Not a state, an absence.
  Rendered as a hatched void. **Never interpolated across.**
- **`.clenched`** — clench index above threshold. Checked *before* focus, because a clenched window's
  focus number is not trustworthy and must not be counted as concentration.
- **`.focused`** — focus ≥ 60 (the existing `flowThreshold`).
- **`.daydream`** — focus well below baseline (< 40) **and** α elevated, while signal is clean and
  the jaw is quiet. This is the mind-wandering signature: disengagement with alpha rising. Labelled
  **"mind-wandering candidate"**, never asserted as a fact about your inner life.
- **`.calm`** — high α, low β, focus near or below baseline without the daydream α-rise profile.
- **`.neutral`** — everything else.

All states require a **minimum dwell of 15 s** (hysteresis), or the timeline strobes and means
nothing.

## Activity context

`Context/`. Three real sources, none inferred:

- **Calendar** — `EKEventStore` (EventKit). Google Calendar already syncs into macOS Calendar, so
  real meetings, 1:1s and on-call blocks arrive with no OAuth and no API key. Classified by title /
  location / URL: `zoom.us` ⇒ meeting, `on-call`/`oncall` ⇒ on-call, `design`/`figma` ⇒ design.
  Requires `com.apple.security.personal-information.calendars` + `NSCalendarsFullAccessUsageDescription`.
- **Frontmost app** — `NSWorkspace.didActivateApplicationNotification` plus a 5 s poll of
  `frontmostApplication.bundleIdentifier`. Bundle-ID → activity map: Xcode / VS Code / Terminal /
  Warp / iTerm / Claude ⇒ coding; Figma / Sketch ⇒ design; zoom.us / Teams ⇒ meeting; Slack ⇒ comms.
  Samples coalesce into spans (same kind ≥ 60 s; gaps < 30 s merged). Bundle ID only — **no window
  titles, no keystrokes, no screen content.**
- **Self-report markers** — a hotkey and a chip row. `break`, `walk`, `stressed`, `anxious`,
  `coffee`, plus a free note. This is where *"too much stress, took a break"* and *"went out for a
  walk"* live, tagged `source: "self"`, because that is exactly what they are.

## Storage

`~/Desktop/neurosync-local/`, JSON, human-readable, atomically written.

```
neurosync-local/
  index.json                      schema version + session manifest
  sessions/<iso8601>--<uuid>.json one file per session
  days/<yyyy-mm-dd>.json          derived rollup — regenerable, safe to delete
  markers.jsonl                   append-only self-report log
```

A session record carries: device + `sps` + scale settings, the frozen baseline, **1 Hz epochs**
(focus, calm, clench, engagement, band powers, α-peak, RMS, the three gate flags, resolved state),
the activity spans, and the markers. 1 Hz × 8 h ≈ 29k epochs ≈ a few MB — fine, and enough
resolution for a minute-grain timeline.

Epochs are downsampled from the engine's native 8 Hz by aggregating each second. **Gated-out epochs
are written with their gate flags and a null score — never omitted, never back-filled.** A gap in
the data is data.

**App Sandbox is ON.** Desktop is not writable by default. `Data/Store.swift` tries the
`com.apple.security.temporary-exception.files.home-relative-path.read-write` entitlement first
(`Desktop/neurosync-local/`), and on failure falls back to an `NSOpenPanel` + security-scoped
bookmark persisted in `UserDefaults`. Either way the data lands exactly where asked.

## The Day view

`UI/DayView.swift`. A 24 h ribbon over four lanes, plus a segment table, findings, and panels.

**Ribbon lanes** (`UI/DayRibbon.swift`, Canvas):

1. **Activity** — coloured spans from calendar + app-watch + manual.
2. **Brain state** — per-minute state colour. Gaps are drawn as gaps.
3. **Focus** — the 0–100 line, with the baseline (50) and flow line (60) marked.
4. **Markers** — pins for the self-reported events.

**Segment table** — one row per activity block:

> `CLAUDE CODING · 14:02–15:44 · 1h42m` — median focus **38** (your baseline is 50).
> 31% of the block read as mind-wandering. 12% clenched. Coverage 76%.

**Findings** (`Data/DayRollup.swift`) — this is the "just say it when focus is fucked" surface.
Generated, ranked, and each one carries its caveat:

- *"Focus sat below your baseline for 31 of the 42 minutes labelled **Claude coding** (14:02–14:44)."*
- *"Clench load was high for 18% of the **on-call** block — β is contaminated there. Treat focus in
  that window as unreliable."*
- *"Longest sustained flow: 22 min, during **design session**."*
- Footer, always: *Association only. Difficulty, fatigue and time of day are not controlled.*

**Panels** — Cognitive Strain and Mental Recovery as **explicitly-labelled proxies** (from α
suppression + EMG load, *not* FMθ); the Berger α-suppression strip (real, and the effect the v5
validation is built on); and Brain Age, which ships as a panel that states it has no defensible
basis on any channel count and exists only for marketing parity.

## Synthetic days

The wall, in four parts:

1. **Synthetic means synthetic *waveforms*, not synthetic scores.** `Synthetic/SyntheticSignal.swift`
   generates raw ADC counts — pink noise, α bursts, β modulated by an engagement envelope, EMG
   bursts, blink transients, electrode-off segments. Those counts go through the **real
   `FocusEngine`** at a real SPS. Every number in a synthetic session is computed by the same DSP
   that a real brain goes through. Nothing is typed in.
2. **Every synthetic record is flagged** — `"synthetic": true` in the JSON, set by the generator and
   nowhere else.
3. **Every synthetic surface is watermarked** — a diagonal hatch plus a permanent amber
   `SYNTHETIC — GENERATED, NOT MEASURED` ribbon, and a separate colourway. It cannot be screenshotted
   without the label.
4. **Synthetic data is banned from the trusted surfaces** — never the menu bar, never the live gauge,
   never blended into an aggregate containing real sessions. Pinned by tests
   (`syntheticSessionsAreAlwaysWatermarked`, `menuBarNeverReadsPersistedData`).

Generation is explicit — a button in the Day view's empty state and a `--generate-synthetic` launch
argument. It never runs on its own.

## Testing

Pure units (`Core/BrainState.swift`, `Data/DayRollup.swift`, `Data/SessionRecord.swift`) are tested
without a radio, a window, or a main actor, like `Core/Gate.swift` is. The load-bearing tests:

- `detachedElectrodeNeverReadsAsHighFocus` — existing, must still pass.
- `withheldEpochsAreNeverInterpolated` — a gap stays a gap through rollup.
- `clenchedWindowsAreNotCountedAsFocus`
- `daydreamRequiresCleanSignalAndQuietJaw`
- `syntheticSessionsAreAlwaysWatermarked`
- `findingsAlwaysCarryTheConfoundLine`
- Round-trip: session → JSON → session is lossless.

Snapshot tests render the populated Day view to PNG via the existing `ImageRenderer` harness, so the
dashboard can be reviewed without hardware.
