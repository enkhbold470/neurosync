//
//  SyntheticSignal.swift
//  neurosync
//
//  ⚠️  THE ONLY GENERATED THING IN THIS APP, AND IT GENERATES WAVEFORMS — NEVER SCORES.
//
//  Manifesto II says "no simulations dressed as data", and the shape of that rule matters more than
//  a blanket ban. What it forbids is a fabricated NUMBER: a focus score that was typed in, or curved,
//  or eased toward a value that flatters the product. That is a lie about a brain.
//
//  What this file makes is a VOLTAGE. It emits raw ADC counts — pink background, band-limited noise
//  in each rhythm, broadband EMG when the jaw is set, blink transients, 60 Hz mains, and stretches
//  where the electrode is simply off the skin. Those counts go into the same `FocusEngine`, through
//  the same gates and the same state machine, as a real board's. Every number that comes out the far
//  side was COMPUTED, by the DSP, from a signal. If the generator makes a bad signal, the gates
//  refuse it and the refusal is what lands on disk.
//
//  So the honesty rules for this file are:
//
//    1. Nothing here may write a focus, calm or clench value. It has no access to one and must not
//       acquire one. It shapes physics; the DSP does the rest.
//    2. Everything it produces is flagged `synthetic: true` at the record level and carries a
//       provenance `syntheticNote`; Store.write refuses a synthetic record that lacks one.
//    3. It is never invoked implicitly. No first-run seeding, no empty-state auto-fill.
//
//  A worked example of why this is not a loophole: the "meeting" profile below sets a loud jaw. The
//  generator does not decide that a meeting scores badly — it decides that you were talking. The EMG
//  it emits lands in beta, which is the focus NUMERATOR, so the raw score goes UP. The clench gate
//  is what catches it and marks the window contaminated. That behaviour was not scripted. It fell
//  out of the physics, exactly as it does on a real head, and it is the whole thesis of the product.
//

import Foundation

// MARK: - Deterministic noise

/// xorshift64*. Seeded, so a given day regenerates byte-identically and a snapshot test can pin it.
nonisolated struct Rng {
    private var s: UInt64

    init(seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        s ^= s >> 12; s ^= s << 25; s ^= s >> 27
        return s &* 2685821657736338717
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Standard normal, Box–Muller.
    mutating func normal() -> Double {
        let u1 = max(1e-12, uniform())
        let u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// A bank of sinusoids filling one band. The band's power is EXACT and it does not leak.
///
/// The obvious way to synthesise a rhythm is to band-pass white noise. Do not: a 4th-order
/// Butterworth band-pass has soft skirts, and for a narrow band like alpha (8–13 Hz) a large share
/// of the output power lands OUTSIDE the band. Measured, the alpha generator was dumping ~25% of its
/// energy into beta — enough that turning alpha up and beta down (a daydream) left the measured beta
/// power almost unchanged, and the Pope index barely moved. The day script could not steer the DSP
/// at all, and the states it was supposed to demonstrate never appeared.
///
/// `n` sinusoids at random frequencies inside the band, each with a random phase, are band-limited
/// exactly. Total power is `n · a²/2`, so `a = sqrt(2P/n)` hits a target band power on the nose. The
/// PSD is textured rather than a single spike, and the pink background supplies the 1/f the real
/// thing sits on.
nonisolated struct BandBank {
    private let freqs: [Double]
    private var phases: [Double]
    private let dp: [Double]
    private let n: Double

    /// `centre` and `sigma` bias the frequency draw toward a peak — used for alpha, so the trace
    /// carries a real IAF the Berger panel can resolve rather than a flat smear.
    init(fs: Double, lo: Double, hi: Double, count: Int = 18,
         centre: Double? = nil, sigma: Double = 1.0, seed: UInt64) {
        var rng = Rng(seed: seed)
        var f: [Double] = [], p: [Double] = []
        for _ in 0..<count {
            let raw = centre.map { $0 + sigma * rng.normal() } ?? (lo + (hi - lo) * rng.uniform())
            f.append(min(hi, max(lo, raw)))
            p.append(2 * .pi * rng.uniform())
        }
        freqs = f
        phases = p
        dp = f.map { 2 * .pi * $0 / fs }
        n = Double(count)
    }

    /// One sample at the requested BAND POWER (µV²).
    mutating func step(power: Double) -> Double {
        guard power > 0 else {
            for i in phases.indices { phases[i] += dp[i] }
            return 0
        }
        let a = sqrt(2 * power / n)
        var y = 0.0
        for i in phases.indices {
            y += a * sin(phases[i])
            phases[i] += dp[i]
        }
        return y
    }
}

// MARK: - Profiles

/// A target spectrum, in BAND POWER (µV²). Not a score — a spectrum.
///
/// These are the only knobs the day script has. It says "alpha was loud and beta was quiet here";
/// it does not, and cannot, say "focus was 28 here".
nonisolated struct SynthProfile: Sendable {
    var delta: Double
    var theta: Double
    var alpha: Double
    var beta: Double
    /// Broadband jaw EMG, as BAND POWER (µV²), spread over 20–45 Hz.
    ///
    /// Deliberately NOT confined to the gamma band. Real temporalis EMG is broadband, so ~40% of
    /// this lands in beta (20–30 Hz) and ~60% above it. The beta share is the whole problem: beta is
    /// the focus NUMERATOR, so a loud jaw drives the engagement index UP. That is why a clenched jaw
    /// reads as concentration on one channel, and why the clench gate has to exist.
    var emg: Double
    /// Blinks per minute.
    var blinkRate: Double
    /// The electrode is off the skin. Everything collapses to the ADC noise floor and the signal
    /// gate closes. Used for the moments you adjust the headset or take it off.
    var electrodeOff: Bool = false

    /// Eyes-open, working, unremarkable. This is what the 20 s calibration window sees, so it is
    /// the thing every other profile is implicitly measured against. E0 ≈ 0.6.
    static let baseline = SynthProfile(delta: 30, theta: 64, alpha: 49, beta: 64, emg: 8, blinkRate: 13)

    /// Beta up, alpha down. Engaged. Scores ~70 — above the flow line.
    static let focused = SynthProfile(delta: 24, theta: 56, alpha: 36, beta: 90, emg: 8, blinkRate: 11)

    /// Alpha up, beta down: disengaged, ~28. Whether this reads as DAYDREAM or as CALM is decided by
    /// the activity block it lands in, not here — see `resolveState`.
    static let disengaged = SynthProfile(delta: 34, theta: 64, alpha: 121, beta: 55, emg: 8, blinkRate: 15)

    /// Deep alpha. The Berger effect: eyes shut, alpha floods in.
    static let resting = SynthProfile(delta: 40, theta: 64, alpha: 256, beta: 36, emg: 6, blinkRate: 6)

    /// Theta creeping up over alpha — the vigilance decrement. Late-afternoon fatigue.
    static let drowsy = SynthProfile(delta: 70, theta: 144, alpha: 110, beta: 40, emg: 6, blinkRate: 18)

    /// Talking. The jaw works constantly, so EMG floods beta AND gamma.
    /// The raw score GOES UP here. The clench gate is the only thing stopping that from being
    /// reported as fifty minutes of exceptional concentration.
    static let talking = SynthProfile(delta: 30, theta: 64, alpha: 45, beta: 64, emg: 100, blinkRate: 12)

    /// Jaw set, not talking — the tension clench. Louder still, and no cortical change at all.
    static let clenching = SynthProfile(delta: 30, theta: 60, alpha: 42, beta: 62, emg: 160, blinkRate: 10)

    static let off = SynthProfile(delta: 0, theta: 0, alpha: 0, beta: 0, emg: 0, blinkRate: 0, electrodeOff: true)

    func lerp(to other: SynthProfile, _ u: Double) -> SynthProfile {
        let t = min(1, max(0, u))
        func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return SynthProfile(
            delta: m(delta, other.delta), theta: m(theta, other.theta),
            alpha: m(alpha, other.alpha), beta: m(beta, other.beta),
            emg: m(emg, other.emg), blinkRate: m(blinkRate, other.blinkRate),
            electrodeOff: t < 0.5 ? electrodeOff : other.electrodeOff
        )
    }
}

/// A stretch of the session held at (or ramped toward) a profile.
nonisolated struct SynthBlock: Sendable {
    var startSec: Double
    var durationSec: Double
    var profile: SynthProfile
    /// Seconds spent ramping in from the previous block. Brains do not step-change.
    var rampSec: Double = 45
}

// MARK: - Synthesis

nonisolated func uvToCounts(_ uv: Double, _ s: ScaleSettings = .v4) -> Double {
    let halfScaleCodes = pow(2.0, Double(s.bipolar ? s.adcBits - 1 : s.adcBits))
    let uvAdc = uv * (s.gain > 0 ? s.gain : 1)
    return uvAdc / ((s.vref * 1e6) / halfScaleCodes) + s.offset
}

/// The raw ADC count stream for a scripted session. This is the ONLY thing the generator returns.
///
/// Note what is absent from the signature: there is no way for a caller to ask for a focus score,
/// and no way for this function to return one.
nonisolated func synthesizeCounts(
    blocks: [SynthBlock],
    fs: Double,
    durationSec: Double,
    seed: UInt64,
    scale: ScaleSettings = .v4,
    line: Double = 60
) -> [Int32] {
    var rng = Rng(seed: seed)

    var deltaB = BandBank(fs: fs, lo: 1.0, hi: 4, count: 10, seed: seed &+ 1)
    var thetaB = BandBank(fs: fs, lo: 4, hi: 8, count: 14, seed: seed &+ 2)
    // Alpha is drawn around a real individual alpha frequency, so the Berger panel has a peak to
    // resolve rather than a flat smear. IAF is a genuine per-subject constant.
    var alphaB = BandBank(fs: fs, lo: 8, hi: 13, count: 16, centre: 10.2, sigma: 0.9, seed: seed &+ 3)
    var betaB  = BandBank(fs: fs, lo: 13, hi: 30, count: 24, seed: seed &+ 4)
    // 20–45 Hz: broadband, exactly like real muscle. ~40% of this lands INSIDE beta.
    var emgB   = BandBank(fs: fs, lo: 20, hi: 45, count: 28, seed: seed &+ 5)

    let n = Int(durationSec * fs)
    var out = [Int32](repeating: 0, count: n)

    var linePhase = 0.0

    // A slow deflection, ~400 ms. Deliberately slow: a sharper blink would splash energy into theta,
    // which is the focus DENOMINATOR, and the day script would be steering the score by accident.
    // At 400 ms the energy sits in delta, where nothing reads it.
    var blinkLeft = 0
    var blinkAmp = 0.0
    let blinkLen = Int(0.4 * fs)

    // The 1/f background every EEG trace sits on. Kellet's economy pink filter.
    var p0 = 0.0, p1 = 0.0, p2 = 0.0

    var prev = blocks.first?.profile ?? .baseline

    for i in 0..<n {
        let t = Double(i) / fs

        // Which block, and how far into its ramp.
        var target = prev
        var ramp = 1.0
        for b in blocks where t >= b.startSec && t < b.startSec + b.durationSec {
            target = b.profile
            ramp = b.rampSec > 0 ? min(1, (t - b.startSec) / b.rampSec) : 1
            if ramp >= 1 { prev = b.profile }
            break
        }
        let p = prev.lerp(to: target, ramp)

        var uv: Double

        if p.electrodeOff {
            // Off the skin: the ADC's own noise floor and nothing else. RMS lands well under the
            // 1.5 µV gate, so the engine withholds — which is the entire point of including this.
            uv = 0.28 * rng.normal()

            // Keep the oscillator phases advancing so the signal does not jump when the pad goes
            // back on.
            _ = deltaB.step(power: 0); _ = thetaB.step(power: 0)
            _ = alphaB.step(power: 0); _ = betaB.step(power: 0); _ = emgB.step(power: 0)
        } else {
            let w = rng.normal()
            p0 = 0.99765 * p0 + w * 0.0990460
            p1 = 0.96300 * p1 + w * 0.2965164
            p2 = 0.57000 * p2 + w * 1.0526913
            // 1/f, so nearly all of this lands in delta — below every band the score is built from.
            let pink = (p0 + p1 + p2 + w * 0.1848) * 0.55

            uv = pink
            uv += deltaB.step(power: max(0, p.delta))
            uv += thetaB.step(power: max(0, p.theta))
            uv += alphaB.step(power: max(0, p.alpha))
            uv += betaB.step(power: max(0, p.beta))
            uv += emgB.step(power: max(0, p.emg))

            // 60 Hz mains. Present at every real electrode; the analysis chain notches it out, and
            // including it is how we prove the notch is doing something.
            linePhase += 2 * .pi * line / fs
            uv += 3.5 * sin(linePhase)

            if blinkLeft > 0 {
                let u = 1 - Double(blinkLeft) / Double(blinkLen)
                uv += blinkAmp * sin(.pi * u)
                blinkLeft -= 1
            } else if p.blinkRate > 0, rng.uniform() < p.blinkRate / 60.0 / fs {
                blinkLeft = blinkLen
                blinkAmp = 40 + 25 * rng.uniform()
            }
        }

        let counts = uvToCounts(uv, scale)
        out[i] = Int32(max(-8_388_608, min(8_388_607, counts.rounded())))
    }

    return out
}
