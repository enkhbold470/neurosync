//
//  BrainState.swift
//  neurosync
//
//  What the brain was doing in one second, as far as one around-ear channel can honestly tell.
//
//  This is deliberately pure and nonisolated, like Core/Gate.swift, because it is the thing the
//  whole Day view is built out of and it must be testable without a radio, a window, or a clock.
//
//  The states are ordered by TRUST, not by interest. `.withheld` and `.clenched` are checked before
//  anything flattering, because the two ways this instrument lies are:
//
//    1. a detached electrode reads as flawless concentration, and
//    2. a clenched jaw reads as concentration, because temporalis EMG lands in beta.
//
//  A state machine that checks `.focused` first would print both of those as focus.
//

import Foundation

// MARK: - States

nonisolated enum BrainState: String, Codable, CaseIterable, Sendable {
    /// A gate is closed. Not a state — an absence. Never interpolated across, never averaged into
    /// anything, never counted in a denominator except "coverage".
    case withheld
    /// Jaw/temporalis EMG is well above your own resting baseline. The focus number in this window
    /// is contaminated and is NOT counted as concentration.
    case clenched
    /// Pope index at or above the flow line, relative to your own frozen baseline.
    case focused
    /// Alpha-up disengagement DURING A BLOCK YOU MEANT TO CONCENTRATE IN. The mind-wandering
    /// candidate. Identical in the spectrum to `.calm` — the activity context is the only thing
    /// that tells them apart, and it is the caller who supplies it.
    case daydream
    /// The same alpha-up disengagement, outside an effortful block: rest. On a walk this is the
    /// system working, not failing.
    case calm
    /// Measured, trustworthy, and none of the above.
    case neutral

    var label: String {
        switch self {
        case .withheld: return "WITHHELD"
        case .clenched: return "CLENCHED"
        case .focused: return "FOCUSED"
        case .daydream: return "DAYDREAM"
        case .calm: return "CALM"
        case .neutral: return "NEUTRAL"
        }
    }

    /// What the state actually claims — shown on hover, so no one has to guess.
    var meaning: String {
        switch self {
        case .withheld:
            return "No trustworthy score. A gate was closed: no biosignal, an indefensible sample rate, or still calibrating."
        case .clenched:
            return "Jaw EMG well above your resting baseline. 30–45 Hz at an earpad is temporalis muscle, and it bleeds into beta — so focus here is contaminated and is not counted as concentration."
        case .focused:
            return "Engagement index at or above your flow line, relative to your own baseline for this session."
        case .daydream:
            return "Engagement well below your baseline while alpha rose, on a clean signal and a quiet jaw — inside a block you meant to concentrate in. The spectrum here is identical to CALM; what makes it a daydream is that you were supposed to be working. A candidate, not a verdict about what you were thinking."
        case .calm:
            return "Alpha up, engagement down, outside an effortful block: rest. The same spectrum as DAYDREAM, and the difference is the calendar, not the brain."
        case .neutral:
            return "Measured and trustworthy, but not distinctly any of the other states."
        }
    }
}

// MARK: - Thresholds

/// Above this the jaw is loud enough that beta — and therefore focus — cannot be trusted.
/// 50 is your own resting jaw, so 70 is well clear of it.
nonisolated let clenchThreshold = 70.0

/// Below this, engagement has fallen meaningfully under your own baseline (50).
nonisolated let disengagedThreshold = 40.0

/// Alpha share (`calm`, 0..100) above this counts as "alpha rose".
nonisolated let alphaRisenThreshold = 55.0

/// No state may be reported until it has held for this long. Without it the ribbon strobes at the
/// engine's 8 Hz update rate and means nothing.
nonisolated let minimumDwellSec = 15.0

// MARK: - Resolution

/// The state of one instant. Ungated inputs in, honest state out.
///
/// Order is load-bearing — see the file header.
///
/// `effortful` is NOT a cosmetic parameter, and it is the most honest line in this file:
///
///   **The EEG cannot tell a daydream from a rest.** Alpha-up disengagement is the same signal
///   whether your mind wandered off the compiler or you shut your eyes on a park bench. One
///   around-ear channel does not know which, and no amount of DSP will make it know.
///
///   What separates them is whether you were *supposed* to be concentrating. That is context — a
///   calendar block, a frontmost app — not brain. So the caller supplies it, and the same spectrum
///   resolves to `.daydream` inside a coding block and `.calm` on a walk.
///
/// Encoding it this way means the app can never quietly claim to have detected mind-wandering from
/// the signal alone, because the signature it would need does not exist.
nonisolated func resolveState(_ m: FocusMetrics, effortful: Bool) -> BrainState {
    guard m.trustworthy else { return .withheld }

    // Checked before anything flattering: temporalis EMG lands in beta, so a clenched jaw raises the
    // focus numerator. This branch is the difference between an instrument and a horoscope.
    if m.clench >= clenchThreshold { return .clenched }

    if m.focus >= flowThreshold { return .focused }

    let alphaRisen = m.calm >= alphaRisenThreshold

    if m.focus < disengagedThreshold {
        // Disengaged. The alpha rise separates "mind went somewhere" from "signal is just flat".
        guard alphaRisen else { return .neutral }
        return effortful ? .daydream : .calm
    }

    return alphaRisen ? .calm : .neutral
}

// MARK: - Hysteresis

/// Smooths the label so the ribbon doesn't strobe at the engine's update rate, while keeping
/// `.withheld` meaning exactly one thing: NO TRUSTWORTHY SIGNAL.
///
/// Two asymmetries, both load-bearing:
///
///   * **Losing signal takes effect immediately.** `instant == .withheld` sets the label at once,
///     because continuing to report `.focused` for 15 s after the electrode falls off is the exact
///     failure this app exists to refuse.
///
///   * **`.withheld` is never a fallback for indecision.** The moment the signal is trustworthy
///     again the label leaves `.withheld` immediately, adopting the current instantaneous state.
///     The 15 s dwell then applies only BETWEEN real states. Without this, a signal that merely
///     flickers between two real states near a threshold — neither holding 15 s — would leave the
///     smoother stuck at its initial `.withheld` forever, and the timeline would claim "no signal"
///     for a perfectly good but variable stretch of brain. (That bug showed up as ~1700 seconds of
///     trustworthy-but-withheld epochs before this was fixed.)
nonisolated struct StateSmoother {
    private(set) var current: BrainState = .withheld
    private var challenger: BrainState = .withheld
    private var heldFor: Double = 0

    let dwell: Double

    init(dwell: Double = minimumDwellSec) {
        self.dwell = dwell
    }

    /// Advance by `dt` seconds with a freshly resolved instantaneous state.
    mutating func step(_ instant: BrainState, dt: Double) -> BrainState {
        // Signal lost: withheld, now. No dwell.
        if instant == .withheld {
            current = .withheld
            challenger = .withheld
            heldFor = 0
            return current
        }
        // Signal (re)gained while withheld: adopt a real state immediately. `.withheld` must not
        // linger once there is something true to show.
        if current == .withheld {
            current = instant
            challenger = instant
            heldFor = 0
            return current
        }
        // Both real: the ordinary dwell hysteresis, between non-withheld states only.
        if instant == current {
            challenger = current
            heldFor = 0
            return current
        }
        if instant == challenger {
            heldFor += dt
            if heldFor >= dwell {
                current = challenger
                heldFor = 0
            }
        } else {
            challenger = instant
            heldFor = dt
        }
        return current
    }
}
