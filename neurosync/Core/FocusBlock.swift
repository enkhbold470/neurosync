//
//  FocusBlock.swift
//  neurosync
//
//  A Focus Block and the live drift intervention that runs inside it.
//
//  This file is deliberately PURE and nonisolated — like Core/BrainState.swift and Core/Gate.swift —
//  because the two honesty guarantees it exists to hold must be testable without a radio, a Dock, a
//  speaker or a clock:
//
//   1. THE NUDGE FIRES ONLY ON A REAL, GATED STATE TRANSITION. The drift detector is fed the
//      SMOOTHED, GATED BrainState stream — the same `resolveState`/`StateSmoother` output the
//      recorder writes to disk. When any gate is closed that state is `.withheld`, and `.daydream`
//      can never appear (see `resolveState`: `guard m.trustworthy else { return .withheld }`). So a
//      closed gate cannot fire a nudge. There is no channel here that takes a number — the detector
//      never sees a focus score, only a state. It cannot be turned into one that eases or curves a
//      value, because it has nothing to ease.
//
//   2. A WITHHELD SECOND IS NOT A ZERO AND NOT A FOCUS. The recap counts `.focused` seconds and
//      nothing else. A `.withheld` second — a closed gate — is never counted as focus and it breaks
//      a focused run, exactly as it breaks the flow line in the Day view. It is not silently bridged.
//
//  `effortful` is NOT decided here. The block being active IS the honest source of effortful context
//  the caller passes to `resolveState` — the user declared, by starting the block, that they meant to
//  concentrate. It is never inferred from the brain state; doing so would make every daydream finding
//  circular (see the note in Core/BrainState.swift).
//

import Foundation

// MARK: - Config

nonisolated struct FocusBlockConfig: Sendable, Equatable {
    /// Default block length offered in the menu bar.
    var plannedMinutes = 25
    /// D — how long the smoothed state must dwell in `.daydream` (inside an effortful block) before a
    /// nudge fires. Longer than the state smoother's own 15 s dwell, so the state is already settled.
    var driftDwellSec = 20.0
    /// M — the debounce. At most one nudge per this many seconds, so a long slump is one cue, not a
    /// storm. See `DriftIntervention.step`.
    var debounceSec = 120.0
}

// MARK: - The drift detector

/// Watches the gated `BrainState` stream during an active block and decides when to fire ONE nudge.
///
/// Pure: `step` takes a state and a `dt`, returns whether a nudge fires this instant. No sound, no
/// Dock, no menu bar — the caller owns the side effects. `reset()` on block end or signal loss.
nonisolated struct DriftIntervention: Equatable {
    var driftDwellSec = 20.0
    var debounceSec = 120.0

    private(set) var nudges = 0

    /// Seconds continuously in `.daydream`. Any other state (including `.withheld`) zeroes it.
    private var daydreamFor = 0.0
    /// Seconds since the last nudge. Seeded to `.infinity` so the FIRST qualifying drift may fire.
    private var sinceLastNudge = Double.infinity

    init(driftDwellSec: Double = 20.0, debounceSec: Double = 120.0) {
        self.driftDwellSec = driftDwellSec
        self.debounceSec = debounceSec
    }

    /// Advance by `dt` seconds with the freshly resolved, SMOOTHED, GATED state. Returns `true` on
    /// the instant a nudge should fire.
    ///
    /// A closed gate arrives here as `.withheld` (never `.daydream`), so it zeroes the dwell and
    /// nothing fires — that is guarantee #1. The debounce is the sole rate limiter once dwelling, so
    /// a sustained daydream produces at most one nudge per `debounceSec`, never a nag storm.
    mutating func step(state: BrainState, dt: Double) -> Bool {
        let d = max(0, dt)
        sinceLastNudge += d

        guard state == .daydream else {
            daydreamFor = 0
            return false
        }
        daydreamFor += d

        if daydreamFor >= driftDwellSec && sinceLastNudge >= debounceSec {
            nudges += 1
            sinceLastNudge = 0
            return true
        }
        return false
    }

    /// No active block, or the signal is gone: start clean. The next drift must re-earn its nudge.
    mutating func reset() {
        daydreamFor = 0
        sinceLastNudge = .infinity
    }
}

/// The single decision the model makes each second: advance the drift detector, and only if a block
/// is active. Pulled out of `VertexModel` so BOTH honesty rules it enforces are testable without a
/// radio or a clock:
///
///   * `blockActive == false` → the detector is never fed, so no nudge can fire outside a block.
///   * a closed gate reaches here as `.withheld` (see `resolveState`) → the detector zeroes its
///     dwell, so no nudge can fire behind a gate.
///
/// Production (`VertexModel.blockStep`) and the tests call this same function, so the guarantee the
/// tests pin is the one the app runs.
nonisolated func driftStep(_ detector: inout DriftIntervention,
                           blockActive: Bool, state: BrainState, dt: Double) -> Bool {
    guard blockActive else { return false }
    return detector.step(state: state, dt: dt)
}

// MARK: - Active block

/// The live state of a running Focus Block. Value type, so a view reads a stable snapshot.
nonisolated struct ActiveBlock: Sendable, Equatable {
    let startedAt: Date
    let plannedMinutes: Int
    /// How many times the drift intervention fired during this block.
    var driftCatches = 0

    var plannedEnd: Date { startedAt.addingTimeInterval(Double(plannedMinutes) * 60) }
    func elapsed(at now: Date) -> TimeInterval { now.timeIntervalSince(startedAt) }
}

// MARK: - Recap

/// The end-of-block summary. Every field is counted from the real DSP epoch stream — the same epochs
/// the recorder writes to disk — never eased, never curved. A `.withheld` second is not focus and not
/// a zero; it is simply not counted, and it breaks a focused stretch.
nonisolated struct BlockRecap: Sendable, Equatable {
    /// Seconds resolved to `.focused`. The honest numerator.
    var focusedSeconds: Int
    /// Seconds a gate was closed. Reported so the recap can never imply full coverage it didn't have.
    var withheldSeconds: Int
    /// Total seconds the block ran.
    var totalSeconds: Int
    /// Longest unbroken run of `.focused` seconds. A withheld second ends the run.
    var longestFocusedStretchSec: Int
    /// Nudges fired — drift caught and flagged, live.
    var driftCatches: Int

    var minutesFocused: Double { Double(focusedSeconds) / 60 }
    var longestFocusedStretchMin: Double { Double(longestFocusedStretchSec) / 60 }

    /// Fraction of the block that produced a trustworthy state. The honest denominator, exactly like
    /// `SessionRecord.coverage`.
    var coverage: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSeconds - withheldSeconds) / Double(totalSeconds)
    }
}

/// Compute the recap from a block's epochs. Pure — the recap and the JSON on disk are built from the
/// same `[Epoch]`, so they can never disagree.
///
/// `.focused` seconds are counted; `.withheld` seconds are counted separately and NEVER as focus, and
/// they break the longest-stretch run rather than being bridged across.
nonisolated func recap(epochs: [Epoch], driftCatches: Int) -> BlockRecap {
    var focused = 0
    var withheld = 0
    var longest = 0
    var run = 0

    for e in epochs {
        switch e.state {
        case .focused:
            focused += 1
            run += 1
            longest = max(longest, run)
        case .withheld:
            withheld += 1
            run = 0                 // a gap is data — it ends the stretch, it is not bridged
        default:
            run = 0                 // anything not-focused ends a focused stretch
        }
    }

    return BlockRecap(
        focusedSeconds: focused,
        withheldSeconds: withheld,
        totalSeconds: epochs.count,
        longestFocusedStretchSec: longest,
        driftCatches: driftCatches
    )
}
