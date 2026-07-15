# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**NeuroSync** — the native macOS instrument for the NeuroFocus **Vertex v4** around-ear dry-EEG
insert. It is a real CoreBluetooth client: it connects to the actual v4 board, decodes the binary
sample stream, and computes the Pope engagement index on-device.

`../CLAUDE.md` (workspace root) is the cross-repo company memory and its **locked facts are
binding here** — this repo is one of the four places they must stay true. Read it first.

### The one rule that shapes everything

> **Manifesto II — Real signal or nothing.** "Every demo is a real brain, in real time. No
> simulations dressed as data. If the alpha suppression isn't on the scope, it doesn't ship."

**No fabricated NUMBER may ever reach a surface.** With no board on a head, the LIVE window shows a
flat line and says `NO DEVICE`. Every number on screen is measured, or computed by the DSP from a
signal, or it is not shown. If you are tempted to type in a focus score, ease one toward a value
that flatters the product, or curve one for a demo video — that is the thing this codebase exists to
refuse, and it has no legitimate form.

**Amended 2026-07-14.** The rule used to read "no signal generator in this app, and none may be
added." `Synthetic/` is now one, so the rule has been made precise rather than quietly broken. What
is forbidden is a fabricated *score*. What `Synthetic/` makes is a fabricated *voltage* — raw ADC
counts, which go through the same `FocusEngine`, the same three gates and the same state machine as
a real board's, and come out the far side as numbers the DSP computed. The generator has no channel
through which to say "focus was 72", and it must never acquire one.

That compromise holds only because of the wall, and the wall is not optional:

- Generated records carry `synthetic: true`, are named `SYNTHETIC--*.json` on disk, and are refused
  by `Store.write` if they lack a provenance note.
- Every UI surface that renders one goes through `.syntheticWatermark(_:)` — a diagonal hatch and an
  amber border, applied at the *root* of the day so no panel inside it can escape, plus a `SYNTHETIC`
  badge on the day-selector tab. (The loud full-width banner was removed at the owner's request on
  2026-07-14; they take on verbal disclosure. The data-level flags below are the real guarantee and
  are untouched.)
- Synthetic data may never reach the menu bar, the live gauge, or any aggregate mixed with real
  sessions. `menuBarNeverReadsPersistedData` pins this.
- Generation is never implicit. No first-run seeding, no empty-state auto-fill.

If you remove the watermark, you have broken Manifesto II and you must say so out loud. The honest
move at that point is to delete this section, not to keep it while contradicting it.

Test fixtures in `neurosyncTests/` remain what they always were: inputs to the real DSP, never
outputs.

### The second rule: say what the hardware can measure, and nothing more

One around-ear dry channel measures **focus** (Pope), **calm** (α share) and **clench** (jaw EMG).
It does **not** measure stress or anxiety, and no amount of DSP will make it. Those are
*self-reported markers* — you press a key, and the app records that you pressed it. See
`Context/Activity.swift`.

Likewise **frontal midline theta cannot be read from an earpad.** FMθ is the best-validated
cognitive-effort marker in the literature and it is sourced to anterior cingulate, read at Fz. The
`COGNITIVE STRAIN` and `MENTAL RECOVERY` panels are labelled `PROXY` because they are proxies. The
`BRAIN AGE` panel ships **empty**, on purpose, and says why.

## Commands

Pure Xcode project, no package manager. Scheme `neurosync`, macOS only (deployment target 26.1,
bundle id `com.inkyg.neurosync`).

```bash
xcodebuild build -scheme neurosync -destination 'platform=macOS,arch=arm64' -quiet

# unit tests (fast, no radio needed — the UI tests launch the app and are slow)
xcodebuild test -scheme neurosync -destination 'platform=macOS,arch=arm64' -only-testing:neurosyncTests

# a single Swift Testing test — the trailing () is REQUIRED. Without it the filter silently
# matches nothing and xcodebuild still exits 0, so you get a green run that ran no tests.
xcodebuild test -scheme neurosync -destination 'platform=macOS,arch=arm64' \
  '-only-testing:neurosyncTests/detachedElectrodeNeverReadsAsHighFocus()'

# Two watermarked synthetic days, for designing the DAY view without hardware. Waveforms are
# generated; every score is computed by the real DSP. Needs a granted data folder (see below).
# This is an explicit opt-in command — it is NEVER run on launch or to fill an empty view.
/path/to/neurosync.app/Contents/MacOS/neurosync --generate-synthetic
```

**Seeing the UI without hardware:** the snapshot tests (`neurosyncTests/Snapshots.swift`) render
the real SwiftUI views to PNG via `ImageRenderer` — no board and no screen-recording permission
needed. They land in the app's sandbox container:
`~/Library/Containers/com.inkyg.neurosync/Data/tmp/neurosync-shots/`.

## Architecture

```
BLE/VertexProtocol.swift   wire contract — UUIDs, frame decode, INFO/DIAG parse, rate ladder
BLE/VertexLink.swift       CoreBluetooth central + DSP, on its own serial queue (nonisolated)
Core/DSP.swift             biquads, filter chain, Welch PSD, band powers, counts→µV
Core/Focus.swift           Pope index, the frozen baseline, focus + calm + CLENCH, the three gates
Core/BrainState.swift      focused/daydream/calm/clenched/withheld, dwell hysteresis (nonisolated)
Core/Gate.swift            which refusal is blocking a score; what the menu bar may say
Context/Activity.swift     activity + marker taxonomy, bundle/calendar classifiers, coalescing
Context/ActivityWatcher.swift  live EventKit (read-only) + frontmost-app (bundle id only) sources
Data/SessionRecord.swift   the on-disk JSON schema; a null score means "withheld", never zero
Data/Recorder.swift        counts→1 Hz epochs (EpochBuilder), shared by live + synthetic paths
Data/Store.swift           ~/Desktop/neurosync-local/, sandbox routes, the synthetic filename wall
Data/DayRollup.swift       segments, the findings engine, the labelled proxies
Synthetic/                 waveform generator + the two scripted days + the --generate-synthetic CLI
App/VertexModel.swift      @MainActor view state; owns the link + live recording, no DSP of its own
App/DayModel.swift         @MainActor state for the DAY view; owns the Store
UI/                        Theme, Scope/Spectrum canvases, Panels, DayRibbon, DayView, Watermark
```

Signal flows one way: `CoreBluetooth → decode → FocusEngine → snapshot → @MainActor`. The link
never touches the UI; the model never touches the radio or the DSP. The DAY view is a second surface
over persisted `SessionRecord`s; it shares the `EpochBuilder`/`FocusEngine` with the live path so the
JSON on disk can never disagree with the window it was recorded from. The menu bar reads the live
model and ONLY the live model — persisted data, synthetic or real, has no path to it.

### The daydream is context, not signal — read this before touching `resolveState`

`resolveState(_:effortful:)` takes a Bool the EEG cannot supply. **Alpha-up disengagement is the
same spectrum whether you daydreamed at the compiler or rested on a walk** — one channel does not
know which. What separates `.daydream` from `.calm` is whether you were *supposed* to be
concentrating, and that is a calendar/app fact, passed in by the caller. This is deliberate: it means
the app can never claim to have *detected* mind-wandering from the signal alone, because the signature
it would need does not exist. Do not "fix" this by inferring `effortful` from the brain state — that
makes every finding circular.

### The three gates are the product

`Core/Focus.swift` will refuse to emit a score. This is not error handling — it is the feature:

- **`signalOk`** — broadband RMS > 1.5 µV. A detached electrode collapses α+θ toward the noise
  floor, so E explodes and an **ungated score reads as flawless concentration from an earpad
  sitting on a desk.** When the gate closes the score **freezes** at its last good value; it
  does not decay and it must never spike. Pinned by `detachedElectrodeNeverReadsAsHighFocus`.
- **`fsOk`** — only 175/330/600/1000/2000 SPS. Below 175 the index is indefensible: β reaches
  30 Hz, and **60 Hz mains aliases straight into the β band** at 45 SPS (→15 Hz) and 90 SPS
  (→30 Hz), where it cannot be notched. Mains hum then reads as concentration.
- **`calibrating`** — 20 s, median of 160 gated updates, then **frozen forever**. Until E0 exists
  there is no baseline to be 50% of.

## Things that will bite you

- **The firmware is the source of truth for the wire protocol.** Derive anything in `BLE/` from
  `../neurofocus/firmware/v4/src/` — never from memory, and never from `docs/CODEBASE_MEMORY.md`,
  which is stale on the device name, the cmd-char properties, and the data encoding.
- **The command characteristic also NOTIFIES.** `INFO` and `DIAG` come back on it, not on the data
  stream, and the peripheral silently drops a notify whose CCCD isn't enabled. **Subscribe to the
  command characteristic before writing `i`**, or the reply is thrown away and you wait forever.
- **The sample rate survives a BLE reconnect** (it only resets on power cycle). A client that
  assumes the 175 SPS boot default after reconnecting to a board left at 600 renders real 10 Hz
  alpha at ~34 Hz — every frequency slides by the same ratio and the score is quietly garbage.
  **Always read `sps` from `INFO`.** `VertexLink` fails loudly rather than guessing.
- **µV are not µV.** The wire carries **raw ADC counts**; we scale them ourselves
  (`countsToUv`, AD8422 ×100 → 3.93 nV/count at the electrode). The firmware's own `AFE_GAIN` is
  an unmeasured placeholder of `1.0`, so the board's **DIAG µV strings are ADC-referred and read
  ~100× larger**. Never mix the two.
- **The Welch window is a SYMMETRIC Hann** (`n-1` denominator) with **linear** per-segment detrend.
  `scipy.signal.welch` defaults to a *periodic* window and *constant* detrend. Matching scipy here
  would silently shift every band power. Likewise `k = 1.5`, not 1 (focus.ts's header comment is
  misleading on this).
- **Never edit `project.pbxproj` to add files.** All three targets are
  `PBXFileSystemSynchronizedRootGroup`s — a file created on disk under `neurosync/`,
  `neurosyncTests/` or `neurosyncUITests/` joins that target automatically. (Build *settings* do
  still live in the pbxproj — that is how `CODE_SIGN_ENTITLEMENTS` and the Bluetooth usage
  description are wired.)
- **Everything is `@MainActor` by default** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). The DSP
  and the BLE link are explicitly `nonisolated` because they run on a background serial queue.
  Keep them that way — Swift 5 mode will not stop you from breaking this, but Swift 6 will.
- **App Sandbox is ON.** CoreBluetooth needs `com.apple.security.device.bluetooth` in
  `neurosync.entitlements` *and* `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`. Without them
  the radio fails at **runtime**, not build time: `CBCentralManager` reports `.unauthorized` and
  no board is ever found.
- **The radio is created lazily on first `connect()`**, not at launch — powering it up is what
  triggers the macOS permission prompt. Don't move it back into `init()`; it also destabilizes the
  test suite.
- **The ESP32 accepts one BLE central at a time,** and the firmware has no stale-connection
  handling. Always `disconnect()` cleanly; an unclean drop leaves the board pumping notifies into
  a dead link and *not advertising* until the supervision timeout expires.
