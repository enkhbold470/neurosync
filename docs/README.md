# docs/ — the README images

Every image here is rendered from **real SwiftUI views** by `neurosyncTests/Snapshots.swift` through
`ImageRenderer` — no board, no screen recording, no hand-editing. Regenerate them with:

```bash
xcodebuild test -scheme neurosync -destination 'platform=macOS,arch=arm64' -only-testing:neurosyncTests
```

They land in `~/Library/Containers/com.inkyg.neurosync/Data/tmp/neurosync-shots/`; copy the ones
below into this folder. The file numbers match the snapshot names so the mapping stays obvious.

| File | Snapshot test | What drives it |
|---|---|---|
| `01-no-device.jpg` | `snapshotNoDevice()` | **Nothing.** No fixture, no metrics — this is what the app draws with no headset. |
| `10-session.jpg` | `snapshotSessionView()` | A synthetic fixture through the real DSP. The score/chart/finding are computed; the input is a generator, not a person. |
| `04-menubar.png` | `snapshotMenuBar()` | A disconnected `VertexModel` — the real "no board" menu bar. |
| `07-block-recap.png` | `snapshotBlockRecap()` | Two `BlockRecap` values: headset-free (no brain half) beside headset-augmented. |
| `09-board-picker.png` | `snapshotBoardPicker()` | Three `DiscoveredBoard` values. |

The two aurora-heavy shots are JPEG because the gradients cost ~2 MB each as PNG; the rest are PNG
so the small type stays crisp. Retina renders (`scale = 2`) are downscaled to ≤1440 px wide.

Snapshots the suite also produces but the README does **not** use: `snapshotInstrument()`,
`snapshotDayTimeline()`, `snapshotDayVisuals()`, `snapshotDerivedStrip()`, `snapshotGates()` and
`snapshotFocusHomeAppearances()`. They still guard that those views compose, but the views they
render (`Instrument`, `DayView`, `GateBanner`, and the light appearance) are **not reachable in the
shipping window** since the one-page rework — the app presents `SessionScreen` and the menu bar, and
pins dark. Shipping a screenshot of a surface a user cannot open would be the same kind of lie the
rest of this app exists to refuse.
