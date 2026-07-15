//
//  Focus.swift
//  neurosync
//
//  The focus score is the engagement index of Pope, Bogart & Bartolome (1995),
//  "Biocybernetic system evaluates indices of operator engagement in automated task"
//  (PMID 7647180):
//
//      E = beta / (alpha + theta)
//
//  It is NEVER theta/beta — that ratio rises with INattention.
//
//  E is unbounded, so it is mapped to 0..100 by a logistic in log-ratio against a
//  per-user baseline E0 measured once and then FROZEN:
//
//      score = 100 / (1 + (E0/E)^k)
//
//  which is exactly 50 when E == E0. 50 means YOUR OWN baseline. The number is not
//  comparable between people, and only within a session.
//
//  Three gates decide whether a score may be shown at all. They are not decoration:
//
//    signalOk    A detached electrode collapses alpha+theta to the ADC noise floor, so E
//                explodes and an ungated score reads as flawless concentration. Below
//                ~1.5 µV RMS there is no biosignal at all.
//    fsOk        Below 175 SPS the Pope index is not defensible: beta reaches 30 Hz, and
//                60 Hz mains ALIASES INTO THE BETA BAND at 45 and 90 SPS, where it cannot
//                be notched. Mains hum then reads as concentration.
//    calibrating Until E0 is frozen there is no baseline to be 50% of.
//
//  Ported from web-ble-monitor/src/lib/focus.ts. Constants are matched deliberately.
//

import Foundation

// MARK: - Feasibility

nonisolated private let passbandFraction = 0.49
nonisolated private let betaLo = 13.0
nonisolated private let betaHi = 30.0
nonisolated private let denomFloor = 1e-9

nonisolated struct FocusFeasibility: Sendable {
    var ok: Bool
    var reason: String?
}

/// Where `f` lands after folding around Nyquist. Used only to build the message string.
nonisolated func aliasOf(_ f: Double, fs: Double) -> Double {
    guard fs > 0 else { return 0 }
    let m = f.truncatingRemainder(dividingBy: fs)
    let mm = (m + fs).truncatingRemainder(dividingBy: fs)
    return mm <= fs / 2 ? mm : fs - mm
}

/// Can `beta/(alpha+theta)` be measured honestly at this sample rate?
///
/// At line=60 this admits exactly [175, 330, 600, 1000, 2000] of the ADS1220 ladder.
nonisolated func focusFeasibility(fs: Double, line: Double = 60) -> FocusFeasibility {
    let top = passbandFraction * fs
    if top < betaHi {
        return FocusFeasibility(
            ok: false,
            reason: String(
                format: "β (%.0f–%.0f Hz) is above the passband: at %.0f SPS the analysis low-pass stops at %.1f Hz",
                betaLo, betaHi, fs, top)
        )
    }
    if line >= top {
        let fold = aliasOf(line, fs: fs)
        let inBeta = fold >= betaLo && fold <= betaHi
        var reason = String(
            format: "%.0f Hz mains folds to %.1f Hz at %.0f SPS and cannot be notched (%.0f Hz is above the %.1f Hz passband)",
            line, fold, fs, line, top)
        if inBeta { reason += " — directly inside β, the focus numerator" }
        return FocusFeasibility(ok: false, reason: reason)
    }
    return FocusFeasibility(ok: true, reason: nil)
}

// MARK: - Metrics

/// The flow line. Above this the session is "in flow" — relative to YOUR baseline, not anyone else's.
nonisolated let flowThreshold = 60.0

/// Median, not mean: robust to the blink and movement spikes that survive a 20 s window.
nonisolated func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let sorted = xs.sorted()
    let mid = sorted.count >> 1
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

nonisolated struct FocusMetrics: Sendable {
    /// Raw Pope engagement index, beta/(alpha+theta). Unbounded, > 0. Ungated.
    var engagement: Double = 0
    /// 0..100. 50 == this user's own frozen baseline. Zero while calibrating or fs-infeasible.
    var focus: Double = 0
    /// 0..100 alpha share of theta+alpha+beta. A relaxation cue, NOT `100 - focus`.
    var calm: Double = 0
    /// 0..100 jaw/temporalis EMG load. 50 == this user's own frozen resting jaw.
    ///
    /// This is an ARTIFACT INDICATOR, not a cortical measure. 30–45 Hz at an around-ear electrode is
    /// temporalis EMG, not gamma. It is surfaced rather than hidden because it is the exact confound
    /// that makes beta — and therefore focus — untrustworthy: clenching your teeth raises the
    /// engagement index exactly as concentrating does, and one channel cannot separate them.
    /// A high clench reading means "the focus number in this window is contaminated".
    var clench: Double = 0
    /// Gamma share of the active bands, ungated. The raw quantity behind `clench`.
    var gammaShare: Double = 0
    var blinks: Int = 0
    /// µV²/Hz, integrated over each band.
    var bands: BandPowers = [:]
    /// Dominant frequency in 6–14 Hz — the Berger alpha peak. nil if none.
    var alphaPeak: Double?
    /// Broadband RMS of the band-passed signal, µV (electrode-referred).
    var rmsUv: Double = 0
    /// The full one-sided PSD, for the spectrum view.
    var psd: Psd?

    var signalOk: Bool = false
    var warmingUp: Bool = true
    var calibrating: Bool = true
    var calibrationLeftSec: Double = 0
    var baseline: Double?
    /// The frozen resting-jaw gamma share. Nil while calibrating, exactly like `baseline`.
    var clenchBaseline: Double?
    var fsOk: Bool = true
    var fsReason: String?

    /// Every gate open. The one predicate that says "this score may be shown, stored, or counted".
    var trustworthy: Bool { signalOk && fsOk && !calibrating && !warmingUp }

    var inFlow: Bool { trustworthy && focus >= flowThreshold }
}

// MARK: - Engine

nonisolated struct FocusOptions: Sendable {
    var line: Double = 60
    var windowSec: Double = 3
    var smoothing: Double = 0.72
    var calibrationSec: Double = 20
    /// Logistic steepness. NOTE: 1.5, not 1 — focus.ts's header comment illustrates with k=1
    /// but the runtime default is 1.5.
    var k: Double = 1.5
    var blinkK: Double = 4.0
    var blinkFloorUv: Double = 8
    /// Skip calibration by supplying a previously frozen baseline.
    var baselineEngagement: Double?
}

/// Feed it raw ADC counts; it yields gated focus metrics ~8x/second.
///
/// `fs` is fixed at construction because the filter chain, window and FFT size all derive
/// from it. When the board's sample rate changes, build a new engine.
nonisolated final class FocusEngine {
    let fs: Double
    private(set) var metrics = FocusMetrics()

    private let opts: FocusOptions
    private let feasibility: FocusFeasibility
    private let scale: ScaleSettings

    private var analysis: FilterChain
    private var blinkChain: FilterChain

    private let cap: Int
    private let nperseg: Int
    private let updateEvery: Int
    private let refractorySamples: Int

    private var buf: [Double] = []
    private var sinceUpdate = 0
    private var seen = 0

    private var baseline: Double?
    private var calSamples: [Double] = []
    private let calNeeded: Int

    /// The resting-jaw gamma share, frozen alongside the engagement baseline and by the same rule:
    /// median of the gated calibration window, then never touched again.
    private var clenchBaseline: Double?
    private var calClench: [Double] = []

    private var scoreEma = 0.0
    private var scorePrimed = false
    private var calmEma = 0.0
    private var clenchEma = 0.0
    private var clenchPrimed = false

    private var emaSq = 0.0
    private var refractory = 0

    var onBlink: (() -> Void)?

    /// The band-passed, mains-notched µV window — this is the scope trace.
    var window: [Double] { buf }

    init(fs: Double, options: FocusOptions = FocusOptions(), scale: ScaleSettings = .v4) {
        self.fs = fs
        self.opts = options
        self.scale = scale
        self.feasibility = focusFeasibility(fs: fs, line: options.line)

        self.analysis = FilterChain(fs: fs, lo: 1, hi: 45, line: options.line)
        self.blinkChain = FilterChain(fs: fs, lo: 0.5, hi: 6, line: options.line)

        self.cap = max(64, Int((fs * options.windowSec).rounded()))
        self.nperseg = min(nextPow2(Int((fs * 1.4).rounded())), nextPow2(cap) / 2)
        self.updateEvery = max(1, Int((fs / 8).rounded()))
        self.refractorySamples = Int((0.3 * fs).rounded())

        // The budget is counted in UPDATES, not seconds: 20 s x 8 updates/s.
        self.calNeeded = max(1, Int((options.calibrationSec * 8).rounded()))
        self.baseline = options.baselineEngagement

        metrics.fsOk = feasibility.ok
        metrics.fsReason = feasibility.reason
        metrics.calibrating = baseline == nil
        metrics.baseline = baseline
        metrics.calibrationLeftSec = options.calibrationSec
    }

    /// Push one raw ADC count.
    func push(counts: Int32) {
        let uv = countsToUv(Double(counts), scale)
        seen += 1

        // Blink detection runs on its own 0.5–6 Hz chain and never touches the score.
        let b = blinkChain.step(uv)
        emaSq = emaSq * 0.9975 + b * b * 0.0025
        let baselineRms = sqrt(emaSq)
        if refractory > 0 {
            refractory -= 1
        } else if Double(seen) > fs,  // let the baseline settle before arming
                  abs(b) > max(opts.blinkFloorUv, opts.blinkK * baselineRms) {
            metrics.blinks += 1
            refractory = refractorySamples
            onBlink?()
        }

        buf.append(analysis.step(uv))
        if buf.count > cap { buf.removeFirst(buf.count - cap) }

        sinceUpdate += 1
        if sinceUpdate >= updateEvery {
            sinceUpdate = 0
            recompute()
        }
    }

    private func scoreFor(_ e: Double, _ e0: Double) -> Double {
        if e <= 0 { return 0 }
        if e0 <= 0 { return 50 }
        return 100 / (1 + pow(e0 / e, opts.k))
    }

    private func recompute() {
        guard buf.count >= nextPow2(nperseg) else { return }

        let p = welch(buf, fs: fs, nperseg: nperseg, overlap: 0.75)
        let bands = bandPowers(p.freqs, p.psd)

        var sq = 0.0
        for v in buf { sq += v * v }
        let rmsUv = sqrt(sq / Double(buf.count))

        // Below ~1.5 µV RMS after a 1–45 Hz band-pass there is no biosignal at all,
        // only the ADC's own noise floor. This is the detached-electrode gate.
        let signalOk = rmsUv > 1.5

        let theta = bands[.theta] ?? 0
        let alpha = bands[.alpha] ?? 0
        let beta = bands[.beta] ?? 0
        let gamma = bands[.gamma] ?? 0

        let engagement = beta / max(denomFloor, alpha + theta)

        // 30–45 Hz at an earpad is temporalis EMG, not cortical gamma. Its share of the active
        // bands is the jaw-clench tell — and the reason a high focus number can be a lie.
        let gammaShare = gamma / max(denomFloor, theta + alpha + beta + gamma)

        let k = opts.smoothing
        let active = theta + alpha + beta
        if active > 1e-12 { calmEma = calmEma * k + (alpha / active) * (1 - k) }

        // A detached electrode collapses alpha+theta and E explodes. Gate BOTH the
        // baseline collection and the score update on it, or the score reads 100 when
        // the earpad is on the desk.
        if signalOk && feasibility.ok {
            if baseline == nil {
                calSamples.append(engagement)
                calClench.append(gammaShare)
                if calSamples.count >= calNeeded {
                    // Median, not mean: robust to the blink and movement spikes that
                    // survive a 20 s window.
                    baseline = median(calSamples)
                    clenchBaseline = median(calClench)
                }
            } else {
                let s = scoreFor(engagement, baseline!)
                // Prime on the first real reading so the score doesn't crawl up from 0.
                scoreEma = scorePrimed ? scoreEma * k + s * (1 - k) : s
                scorePrimed = true

                if let g0 = clenchBaseline {
                    let c = scoreFor(gammaShare, g0)
                    clenchEma = clenchPrimed ? clenchEma * k + c * (1 - k) : c
                    clenchPrimed = true
                }
            }
        }
        // When signal is lost the score is NOT updated — it freezes at its last good
        // value rather than spiking to 100.

        let calibrating = baseline == nil

        metrics.engagement = engagement
        metrics.focus = (calibrating || !feasibility.ok) ? 0 : scoreEma
        metrics.calm = min(100, calmEma * 160)
        metrics.gammaShare = gammaShare
        metrics.clench = (calibrating || !feasibility.ok) ? 0 : clenchEma
        metrics.clenchBaseline = clenchBaseline
        metrics.bands = bands
        metrics.alphaPeak = peakFreq(p.freqs, p.psd, 6, 14)
        metrics.rmsUv = rmsUv
        metrics.psd = p
        metrics.signalOk = signalOk
        metrics.warmingUp = false
        metrics.calibrating = calibrating
        metrics.calibrationLeftSec = max(0, Double(calNeeded - calSamples.count) / 8)
        metrics.baseline = baseline
        metrics.fsOk = feasibility.ok
        metrics.fsReason = feasibility.reason
    }

    /// Drop the baseline and start calibration over.
    func recalibrate() {
        baseline = opts.baselineEngagement
        clenchBaseline = nil
        calSamples.removeAll()
        calClench.removeAll()
        scoreEma = 0
        scorePrimed = false
        clenchEma = 0
        clenchPrimed = false
        metrics.calibrating = baseline == nil
        metrics.calibrationLeftSec = opts.calibrationSec
        metrics.baseline = baseline
        metrics.clenchBaseline = nil
    }
}
