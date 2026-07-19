//
//  FocusBlock.swift
//  neurosync
//
//  A Focus Block and the live drift intervention that runs inside it.
//
//  THE BLOCK IS HARDWARE-OPTIONAL. It runs in two tiers that stack:
//
//   • Tier 1 — headset-free (always). A timer, an app-context drift detector, and a behavioural
//     recap. The signal is the frontmost app you were in (bundle id only — no titles, no URLs, no
//     keystrokes). This is MEASURED behaviour, not a fabricated brain number, so it never touches
//     Manifesto II.
//
//   • Tier 2 — headset-augmented (when a board is connected). Everything above PLUS the EEG layer:
//     the Pope brain-drift below, minutes of measured focus, coverage.
//
//  This file is deliberately PURE and nonisolated — like Core/BrainState.swift and Core/Gate.swift —
//  because the honesty guarantees it exists to hold must be testable without a radio, a Dock, a
//  speaker or a clock. The two guarantees, restated for the hardware-optional world:
//
//   1. THE NUDGE FIRES ONLY ON A REAL SIGNAL. The EEG drift detector is fed the SMOOTHED, GATED
//      BrainState stream (a closed gate is `.withheld`, never `.daydream`, so a closed gate can
//      never fire). The APP drift detector is fed the measured frontmost-app context — and it only
//      accrues "away" from clearly non-work apps you were actually looking at. Neither detector ever
//      sees a focus SCORE; there is no channel here that takes a number, so none can be eased.
//
//   2. NO BRAIN NUMBER WITHOUT A BRAIN. `BlockRecap.brain` is `Optional`. With no headset there are
//      no brain epochs, so it is `nil`, and the UI has no focus score, no "minutes focused", no
//      coverage to render. A `.withheld` second is never counted as focus and never bridged.
//
//  `effortful` is NOT decided from the signal. Starting a block IS the honest, user-supplied source
//  of effortful context the caller passes to `resolveState` — never inferred from the brain state,
//  which would make every daydream finding circular (see the note in Core/BrainState.swift).
//

import Foundation

// MARK: - Config

nonisolated struct FocusBlockConfig: Sendable, Equatable {
    /// Default block length offered in the menu bar.
    var plannedMinutes = 25
    /// D_brain — how long the smoothed state must dwell in `.daydream` (inside a block) before an EEG
    /// nudge fires. Longer than the state smoother's own 15 s dwell, so the state is already settled.
    var driftDwellSec = 20.0
    /// D_app — how long you must be continuously "away" from a work app before an app-context nudge
    /// fires. Deliberately longer than the EEG dwell: a bundle id is a coarser signal than the brain
    /// state, so we wait longer before saying anything.
    var appDriftDwellSec = 45.0
    /// M — the debounce. At most one nudge per this many seconds, ACROSS BOTH sources, so a long
    /// slump is one cue, not a storm. See `DriftIntervention.step` / `AppDriftDetector.step`, and the
    /// unified model-level guard that spaces the two sources apart.
    var debounceSec = 120.0
}

// MARK: - Work context (the headset-free drift signal)

/// What the frontmost app means for a block, derived ONLY from its `ActivityKind` — which comes from
/// the bundle id and nothing else. Three states, because a bundle id is a coarse, privacy-preserving
/// signal and honesty requires admitting what it cannot see:
///
///   • `.onTask`  — an effortful app (coding/design/reading/meeting). You are where you meant to be.
///   • `.away`    — a clearly non-work app you were looking at (comms like Slack/Mail, or a browser).
///                  A browser is `.away` because leaving your editor for it is a real fact; it is NOT
///                  a claim that the browser is bad. We can't see the tab (docs vs X) and won't, so
///                  the nudge is a neutral check-in ("still on it?"), never an accusation.
///   • `.neutral` — an UNRECOGNISED app. We don't know, so we say nothing: it neither accrues drift
///                  nor rescues you from a slump. An unknown editor must never nag.
nonisolated enum WorkContext: String, Sendable, Equatable {
    case onTask
    case away
    case neutral
}

nonisolated func workContext(for kind: ActivityKind) -> WorkContext {
    if kind.isEffortful { return .onTask }          // coding, design, meeting, onCall, reading
    switch kind {
    case .comms, .browsing: return .away            // Slack/Mail; any browser (tab unknown by design)
    default: return .neutral                         // unknown, breakTime, walk
    }
}

// MARK: - The drift detectors

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

/// The headset-free mirror of `DriftIntervention`: watches the measured app-context stream during a
/// block and decides when to fire ONE gentle "you've been away from your work app" nudge.
///
/// Pure and shaped exactly like `DriftIntervention`, so its guarantees are testable without a radio,
/// a Dock or a clock. `.onTask` zeroes the away dwell (you came back); `.away` accrues it; `.neutral`
/// HOLDS — it neither accrues nor resets, so an unrecognised app never nags AND a brief unknown blip
/// mid-slump doesn't rescue you from the nudge. At most one nudge per `debounceSec`.
nonisolated struct AppDriftDetector: Equatable {
    var awayDwellSec = 45.0
    var debounceSec = 120.0

    private(set) var nudges = 0

    /// Seconds continuously `.away`. `.onTask` zeroes it; `.neutral` holds it.
    private var awayFor = 0.0
    private var sinceLastNudge = Double.infinity

    init(awayDwellSec: Double = 45.0, debounceSec: Double = 120.0) {
        self.awayDwellSec = awayDwellSec
        self.debounceSec = debounceSec
    }

    mutating func step(context: WorkContext, dt: Double) -> Bool {
        let d = max(0, dt)
        sinceLastNudge += d

        switch context {
        case .onTask:
            awayFor = 0
            return false
        case .neutral:
            return false                 // hold: don't accrue, don't reset
        case .away:
            awayFor += d
            if awayFor >= awayDwellSec && sinceLastNudge >= debounceSec {
                nudges += 1
                sinceLastNudge = 0
                return true
            }
            return false
        }
    }

    mutating func reset() {
        awayFor = 0
        sinceLastNudge = .infinity
    }
}

/// The single decision the model makes each second for the EEG tier: advance the brain drift
/// detector, and only if a block is active. Pulled out of `VertexModel` so BOTH honesty rules it
/// enforces are testable without a radio or a clock:
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

/// The headset-free equivalent: advance the app-context drift detector, only inside a block. The same
/// function production and the tests call.
nonisolated func appDriftStep(_ detector: inout AppDriftDetector,
                              blockActive: Bool, context: WorkContext, dt: Double) -> Bool {
    guard blockActive else { return false }
    return detector.step(context: context, dt: dt)
}

// MARK: - Behavioural tally (measured facts, the always-present half)

/// One app's share of a block, for the recap breakdown. Measured seconds in a named app — never a
/// focus claim.
nonisolated struct AppTally: Sendable, Equatable, Identifiable {
    var bundleKey: String
    var kind: ActivityKind
    var label: String
    var seconds: Int
    var context: WorkContext

    var id: String { bundleKey }
    var minutes: Double { Double(seconds) / 60 }
}

/// Accumulates the measured app context of a block, one second at a time. Pure and `Equatable`, so
/// the whole behavioural half of the recap is testable with no `NSWorkspace`, no radio, no clock.
///
/// The `.onTask` stretch counts ONLY recognised effortful apps and is broken by anything else
/// (`.away` or `.neutral`) — it under-claims rather than over-claims, exactly as a `.withheld` second
/// breaks the brain focused-stretch. That is the honest direction to round.
nonisolated struct BehaviorTally: Sendable, Equatable {
    private(set) var totalSeconds = 0
    private(set) var onTaskSeconds = 0
    private(set) var awaySeconds = 0
    private(set) var neutralSeconds = 0
    private(set) var longestOnTaskStretchSec = 0
    private var currentRun = 0
    private var perApp: [String: AppTally] = [:]

    mutating func add(kind: ActivityKind, label: String, bundleId: String?, seconds: Int = 1) {
        guard seconds > 0 else { return }
        totalSeconds += seconds
        let ctx = workContext(for: kind)

        switch ctx {
        case .onTask:
            onTaskSeconds += seconds
            currentRun += seconds
            longestOnTaskStretchSec = max(longestOnTaskStretchSec, currentRun)
        case .away:
            awaySeconds += seconds
            currentRun = 0                       // a slip breaks the on-task stretch, never bridged
        case .neutral:
            neutralSeconds += seconds
            currentRun = 0                       // unknown time is not claimed as on-task either
        }

        let key = bundleId ?? "kind:\(kind.rawValue):\(label)"
        var t = perApp[key] ?? AppTally(bundleKey: key, kind: kind, label: label, seconds: 0, context: ctx)
        t.seconds += seconds
        perApp[key] = t
    }

    /// The behavioural half of the recap. `slips` is the number of app-context nudges the block fired
    /// — a measured count of times you were flagged as away, never a judgement.
    func recap(slips: Int) -> BehaviorRecap {
        BehaviorRecap(
            totalSeconds: totalSeconds,
            onTaskSeconds: onTaskSeconds,
            awaySeconds: awaySeconds,
            longestOnTaskStretchSec: longestOnTaskStretchSec,
            slips: slips,
            topApps: perApp.values.sorted { $0.seconds > $1.seconds }
        )
    }
}

// MARK: - Active block

/// The live state of a running Focus Block. Value type, so a view reads a stable snapshot. The live
/// behavioural counters are refreshed each second by the model so the running display ticks.
nonisolated struct ActiveBlock: Sendable, Equatable {
    let startedAt: Date
    let plannedMinutes: Int
    /// What you said you were here to do, in your words. Optional, self-reported, never inferred.
    let intention: String?
    /// The effortful app the block was anchored to at start ("Xcode"), for the nudge label. Nil if
    /// you started the block from somewhere that wasn't a recognised work app.
    let anchorLabel: String?

    /// How many times a drift intervention fired during this block (either source).
    var driftCatches = 0

    // Live tally, mirrored from the model's `BehaviorTally` each second.
    var onTaskSeconds = 0
    var awaySeconds = 0
    /// The frontmost app right now, for the live "on task · Xcode" line.
    var currentLabel: String?
    var currentContext: WorkContext = .neutral

    var plannedEnd: Date { startedAt.addingTimeInterval(Double(plannedMinutes) * 60) }
    func elapsed(at now: Date) -> TimeInterval { now.timeIntervalSince(startedAt) }
}

// MARK: - Recap

/// The measured, always-present half of the end-of-block summary. Every field is a behavioural fact:
/// time, and which app you were in. THERE IS NO FOCUS FIELD HERE, on purpose — an app is not a brain.
nonisolated struct BehaviorRecap: Sendable, Equatable {
    /// Total seconds the block ran.
    var totalSeconds: Int
    /// Seconds in a recognised effortful app — "on task".
    var onTaskSeconds: Int
    /// Seconds in a clearly non-work app — "away". A neutral fact, not a failure.
    var awaySeconds: Int
    /// Longest unbroken run of on-task seconds. Anything not-on-task ends the run.
    var longestOnTaskStretchSec: Int
    /// Times an app-context nudge fired.
    var slips: Int
    /// Per-app breakdown, longest first.
    var topApps: [AppTally]

    var minutesOnTask: Double { Double(onTaskSeconds) / 60 }
    var minutesAway: Double { Double(awaySeconds) / 60 }
    var longestOnTaskStretchMin: Double { Double(longestOnTaskStretchSec) / 60 }
}

/// The brain half. Present ONLY when a headset produced epochs during the block; otherwise the parent
/// `BlockRecap.brain` is `nil` and no focus number can be rendered. Every field is counted from the
/// real DSP epoch stream — the same epochs the recorder writes to disk — never eased, never curved.
nonisolated struct BrainRecap: Sendable, Equatable {
    /// Seconds resolved to `.focused`. The honest numerator.
    var focusedSeconds: Int
    /// Seconds a gate was closed within the headset window. Never counted as focus.
    var withheldSeconds: Int
    /// Seconds a brain epoch existed at all — the headset coverage window (may be < the whole block).
    var brainSeconds: Int
    /// Longest unbroken run of `.focused` seconds. A withheld second ends the run.
    var longestFocusedStretchSec: Int

    var minutesFocused: Double { Double(focusedSeconds) / 60 }
    var longestFocusedStretchMin: Double { Double(longestFocusedStretchSec) / 60 }

    /// Fraction of the HEADSET WINDOW that produced a trustworthy state — the honest denominator is
    /// the seconds a brain signal existed, not the whole block. A headset on for the last 10 min of a
    /// 25 min block reports coverage over those 10 min, never diluted by the 15 min it was off.
    var coverage: Double {
        guard brainSeconds > 0 else { return 0 }
        return Double(brainSeconds - withheldSeconds) / Double(brainSeconds)
    }
}

/// The full end-of-block summary: the behavioural half always, the brain half only if a headset was
/// on. `hadHeadset` is the single question the UI asks before it dares render a focus number.
nonisolated struct BlockRecap: Sendable, Equatable {
    var behavior: BehaviorRecap
    var brain: BrainRecap?
    var driftCatches: Int

    var hadHeadset: Bool { brain != nil }
}

/// Compute the brain half from a block's epochs. Pure — the recap and the JSON on disk are built from
/// the same `[Epoch]`, so they can never disagree.
///
/// Returns `nil` when there are NO epochs: no headset, no brain half, no focus number anywhere. When
/// epochs exist, `.focused` seconds are counted; `.withheld` seconds are counted separately and NEVER
/// as focus, and they break the longest-stretch run rather than being bridged across.
nonisolated func brainRecap(epochs: [Epoch]) -> BrainRecap? {
    guard !epochs.isEmpty else { return nil }

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

    return BrainRecap(
        focusedSeconds: focused,
        withheldSeconds: withheld,
        brainSeconds: epochs.count,
        longestFocusedStretchSec: longest
    )
}

/// Assemble the whole recap. The behavioural half is measured and always present; the brain half is
/// `brainRecap(epochs:)`, which is `nil` without a headset. This is the one place the two vocabularies
/// meet, and they stay in separate fields.
nonisolated func makeRecap(behavior: BehaviorRecap, epochs: [Epoch], driftCatches: Int) -> BlockRecap {
    BlockRecap(behavior: behavior, brain: brainRecap(epochs: epochs), driftCatches: driftCatches)
}
