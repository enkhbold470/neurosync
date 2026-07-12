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

**There is no demo mode, no sample data, and no signal generator in this app, and none may be
added.** With no board on a head, the window shows a flat line and says `NO DEVICE`. Every number
on screen is measured or it is not shown. If you are ever tempted to add a fake data source "just
for the demo video" — that is the exact thing this codebase exists to refuse.

The only synthetic waveforms in the repo are **test fixtures** (`neurosyncTests/`), which feed the
real DSP to pin its behavior. They are inputs, never outputs.

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
Core/Focus.swift           Pope index, the frozen baseline, and the three gates
App/VertexModel.swift      @MainActor @Observable view state; owns the link, no DSP of its own
UI/                        Theme, Scope/Spectrum/Sparkline canvases, Panels
```

Signal flows one way: `CoreBluetooth → decode → FocusEngine → snapshot → @MainActor`. The link
never touches the UI; the model never touches the radio or the DSP.

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
