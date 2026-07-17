# NeuroSync — Zoomable DAY timeline

**Date:** 2026-07-17
**Status:** approved (design), implementing

Make the DAY view's timeline zoom and pan like a video-editor timeline (Final Cut / Premiere /
DaVinci on macOS), so a whole day and a single 30-second stretch are both legible.

## The seam that makes this cheap

`TimeAxis(start:end:width:)` already maps a time window to pixel width, and all four lanes
(`ActivityLane`, `StateLane`, `FocusLane`, `MarkerLane`) plus the grid draw through `axis.x()` /
`axis.w()`. So the whole feature is: **make the axis represent a visible *sub-window* of the day and
clip to bounds.** Every lane reprojects for free, and the "a gap is a gap" rule is preserved — a gap
just gets wider as you zoom in, never bridged.

No changes to the data model, the rollup, or the honesty rules. This is a `DayRibbon` rewrite plus
one pure, tested viewport type.

## Pieces

- **Viewport** (`TimelineViewport.swift`, pure & `nonisolated`, unit-tested): the day bounds plus a
  visible `start` + `span`, with `clamp`, `zoom(factor:anchor:)` (keeps the time under the anchor
  fixed), `pan(bySeconds:)`, `fit()`, `setRange(_:_:)`. Zoom clamps from "whole day fits" down to a
  60 s floor (data is 1 Hz; finer is meaningless). Pan clamps to the data bounds.
- **Adaptive ruler** (`rulerTicks`, pure & tested): picks a "nice" step from a ladder
  (10s·15s·30s·1m·2m·5m·10m·15m·30m·1h·2h·3h·6h) so ticks stay ≥ ~70 px apart, aligned to absolute
  clock boundaries; returns tick dates + which are major (labelled). Replaces the fixed hour grid.
- **Interactions:**
  - Trackpad **pinch → zoom**, anchored at the cursor (`MagnifyGesture`), and **two-finger scroll →
    pan / ⌘-scroll → zoom** via a defensive `NSViewRepresentable` event catcher (`scrollWheel` +
    `magnify(with:)`). The catcher is a clear event-only overlay; if it no-ops under `ImageRenderer`
    it renders nothing.
  - **Drag on the lanes → grab-pan.** **Drag on the ruler → marquee zoom-to-range.**
  - **Hover scrubber:** `.onContinuousHover` drives a vertical playhead line with a chip reading
    time · focus · brain state · clench at that instant. Only shows values for TRUSTWORTHY epochs;
    over a withheld gap it says WITHHELD, never a number.
  - **Keyboard** (`.onKeyPress`, view focusable): `+`/`-` zoom, `←`/`→` pan, `F` fit.
  - **Controls:** a compact `− · [span readout] · + · Fit` cluster.
  - **Minimap:** a slim full-day state strip with the current viewport drawn as a draggable window;
    drag it to pan.
- **Day switch resets to fit** (`.onChange(of: day.key)`), so every day opens on the overview.

## Honesty carried through

The scrubber reads from the epoch under the cursor and honours the gates: a withheld second shows
`WITHHELD`, never an interpolated value. The minimap and lanes draw gaps as gaps at every zoom. None
of the zoom machinery can invent a sample between two real ones.

## Tests

Pure `Viewport` math (clamp bounds, zoom-keeps-anchor-fixed, zoom floor/ceiling, pan clamp, fit,
setRange) and `rulerTicks` (step selection across zoom levels, alignment, ≥ min spacing). The
existing `snapshotDayTimeline` re-renders at fit zoom to prove the rewrite still composes.
