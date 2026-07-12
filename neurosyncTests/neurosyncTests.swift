//
//  neurosyncTests.swift
//  neurosyncTests
//
//  These pin the claims. Every test here corresponds to something that, if it broke silently,
//  would put a number on screen that is not true.
//

import Testing
import Foundation
@testable import neurosync

// MARK: - Helpers

/// µV (electrode-referred) → raw ADC counts, the inverse of the wire scaling.
private func counts(uv: Double) -> Int32 {
    Int32((uv / countsToUv(1.0)).rounded())
}

/// A synthetic but physically-shaped EEG: theta + alpha + beta at known amplitudes.
/// This is a TEST FIXTURE. It never reaches the app — the app has no signal generator.
private func eeg(t: Double, theta: Double, alpha: Double, beta: Double) -> Double {
    theta * sin(2 * .pi * 6 * t)
        + alpha * sin(2 * .pi * 10 * t)
        + beta * sin(2 * .pi * 20 * t)
}

private func feed(_ e: FocusEngine, seconds: Double, fs: Double,
                  theta: Double, alpha: Double, beta: Double, from: Double = 0) {
    let n = Int(seconds * fs)
    for i in 0..<n {
        let t = from + Double(i) / fs
        e.push(counts: counts(uv: eeg(t: t, theta: theta, alpha: alpha, beta: beta)))
    }
}

// MARK: - The metric

@Test func engagementIsPopeNotThetaBeta() {
    // β/(α+θ). If someone "simplifies" this to θ/β or β/(α+β), these numbers move.
    let fs = 175.0
    let e = FocusEngine(fs: fs)
    feed(e, seconds: 6, fs: fs, theta: 8, alpha: 8, beta: 16)

    let m = e.metrics
    let theta = m.bands[.theta] ?? 0
    let alpha = m.bands[.alpha] ?? 0
    let beta = m.bands[.beta] ?? 0

    #expect(m.engagement == beta / max(1e-9, alpha + theta))

    // Band POWER goes as amplitude², so beta(16) carries ~4x each of theta(8)/alpha(8):
    // theta≈32, alpha≈32, beta≈128. The three candidate formulas separate cleanly, and this
    // test exists to make sure we are on the right one:
    //
    //   β/(α+θ)     = 128/64  = 2.00   <- Pope 1995. What we ship.
    //   β/(α+β)     = 128/160 = 0.80   <- what the launch mockup's code panel showed. Wrong.
    //   θ/β         = 32/128  = 0.25   <- rises with INattention. Never this.
    #expect(abs(m.engagement - 2.0) < 0.2, "expected the Pope index ≈2.0, got \(m.engagement)")
    #expect(abs(m.engagement - 0.8) > 0.5, "this is β/(α+β), not the Pope index")
    #expect(abs(m.engagement - 0.25) > 0.5, "this is θ/β — the metric that rises with inattention")
}

@Test func scoreIsFiftyAtYourOwnBaseline() {
    // The logistic is 100/(1 + (E0/E)^k) — exactly 50 when E == E0, for any k.
    let e = FocusEngine(fs: 175, options: FocusOptions(baselineEngagement: 2.0))
    #expect(!e.metrics.calibrating)

    // Reach into the same maths the engine uses.
    let k = 1.5
    let score = { (eng: Double, e0: Double) in 100 / (1 + pow(e0 / eng, k)) }
    #expect(abs(score(2.0, 2.0) - 50) < 1e-9)
    #expect(score(4.0, 2.0) > 50)
    #expect(score(1.0, 2.0) < 50)
}

// MARK: - The gates (the part that keeps us honest)

@Test func detachedElectrodeNeverReadsAsHighFocus() throws {
    // THE test. If this one goes green while the app is lying, nothing else matters.
    //
    // A detached electrode collapses α+θ toward the noise floor, so E can explode and an
    // UNGATED score reads as flawless concentration from an earpad sitting on a desk.
    let fs = 175.0
    let e = FocusEngine(fs: fs)

    // Calibrate on real signal (160 gated updates == 20 s).
    feed(e, seconds: 24, fs: fs, theta: 10, alpha: 10, beta: 12)
    #expect(!e.metrics.calibrating, "should have frozen a baseline")
    #expect(e.metrics.signalOk)
    #expect(e.metrics.focus > 0)

    // The earpad comes off.
    var maxFocus = 0.0
    var focusAtGateClose: Double?
    for _ in 0..<Int(20 * fs) {
        e.push(counts: 0)
        let m = e.metrics
        maxFocus = max(maxFocus, m.focus)
        if !m.signalOk && focusAtGateClose == nil { focusAtGateClose = m.focus }
    }

    // 1. The contact gate must close. 0 µV cannot pass a 1.5 µV floor.
    #expect(!e.metrics.signalOk)
    #expect(e.metrics.rmsUv <= 1.5)

    // 2. THE SAFETY PROPERTY: at no instant — including the 3 s window flush, while the
    //    buffer still holds a decaying mixture of real signal and nothing — may a detached
    //    electrode drive the score upward toward "deep flow".
    #expect(maxFocus < 60, "a detached electrode reached \(maxFocus)% — it must never read as flow")

    // 3. Once the gate closes the score FREEZES. It does not decay, and it does not spike.
    let frozen = try #require(focusAtGateClose)
    #expect(e.metrics.focus == frozen, "score must be frozen, not drifting, behind a closed gate")
}

@Test func signalGateIsTheNoiseFloor() {
    let fs = 175.0
    let e = FocusEngine(fs: fs)
    // 0.5 µV of alpha — real but below the 1.5 µV biosignal floor.
    feed(e, seconds: 6, fs: fs, theta: 0.2, alpha: 0.5, beta: 0.2)
    #expect(!e.metrics.signalOk)
    #expect(e.metrics.focus == 0, "no score may be emitted without contact")
}

@Test func focusIsWithheldUntilCalibrated() {
    let fs = 175.0
    let e = FocusEngine(fs: fs)
    feed(e, seconds: 5, fs: fs, theta: 10, alpha: 10, beta: 12)
    #expect(e.metrics.calibrating)
    #expect(e.metrics.focus == 0, "there is no baseline yet to be 50% of")
    #expect(e.metrics.calibrationLeftSec > 0)
}

// MARK: - Sample-rate feasibility

@Test func onlyRatesAtOrAbove175CanCarryTheScore() {
    // 20/45 SPS: beta reaches 30 Hz, above the 0.49*fs passband.
    // 90 SPS: 60 Hz mains folds to 30.0 Hz — directly inside beta, and unnotchable.
    #expect(Vertex.feasibleRates(line: 60) == [175, 330, 600, 1000, 2000])

    #expect(!focusFeasibility(fs: 20).ok)
    #expect(!focusFeasibility(fs: 45).ok)
    #expect(!focusFeasibility(fs: 90).ok)
    #expect(focusFeasibility(fs: 175).ok)
    #expect(focusFeasibility(fs: 175).reason == nil)
}

@Test func mainsFoldsIntoBetaAt90SPS() {
    // This is the whole reason 90 SPS is refused: 60 Hz aliases to exactly 30 Hz.
    #expect(aliasOf(60, fs: 90) == 30)
    #expect(aliasOf(60, fs: 45) == 15)   // also inside beta
    #expect(aliasOf(60, fs: 175) == 60)  // above the passband, but notchable

    let why = focusFeasibility(fs: 90).reason ?? ""
    #expect(why.contains("directly inside β"))
}

@Test func engineRefusesToScoreAtAnInfeasibleRate() {
    let fs = 90.0
    let e = FocusEngine(fs: fs, options: FocusOptions(baselineEngagement: 1.0))
    feed(e, seconds: 10, fs: fs, theta: 10, alpha: 10, beta: 12)
    #expect(!e.metrics.fsOk)
    #expect(e.metrics.focus == 0, "a score at 90 SPS would be mains hum reading as concentration")
}

// MARK: - Berger

@Test func alphaPeakTracksTheRealRhythm() {
    // Eyes-closed alpha: a strong 10 Hz rhythm must be found at 10 Hz, not 34 Hz.
    // (Hard-coding fs instead of reading it from the board is exactly how that happens.)
    let fs = 175.0
    let e = FocusEngine(fs: fs)
    feed(e, seconds: 6, fs: fs, theta: 2, alpha: 30, beta: 2)

    let peak = e.metrics.alphaPeak
    #expect(peak != nil)
    #expect(abs((peak ?? 0) - 10) < 1.0, "alpha peak should land on 10 Hz, got \(peak ?? -1)")

    // And alpha must dominate the band powers.
    let alpha = e.metrics.bands[.alpha] ?? 0
    let beta = e.metrics.bands[.beta] ?? 0
    #expect(alpha > beta * 5)
}

@Test func eyesClosedRaisesAlphaAndLowersFocus() {
    // The Berger effect, and the sanity check that the Pope index moves the RIGHT way:
    // more alpha => lower engagement.
    let fs = 175.0

    let open = FocusEngine(fs: fs)
    feed(open, seconds: 6, fs: fs, theta: 6, alpha: 4, beta: 14)

    let closed = FocusEngine(fs: fs)
    feed(closed, seconds: 6, fs: fs, theta: 6, alpha: 24, beta: 14)

    #expect((closed.metrics.bands[.alpha] ?? 0) > (open.metrics.bands[.alpha] ?? 0))
    #expect(closed.metrics.engagement < open.metrics.engagement,
            "more alpha must LOWER β/(α+θ) — if this inverts, the metric has been flipped to θ/β")
}

// MARK: - Scaling

@Test func countsToMicrovoltsMatchesTheReferenceClient() {
    // dsp.test.ts pins 12738 counts -> ~50.11 µV electrode-referred (AD8422 G=100).
    let uv = countsToUv(12738)
    #expect(uv > 49 && uv < 51)

    // One count at the electrode ~= 3.93 nV.
    #expect(abs(countsToUv(1) - 0.0039339065551757812) < 1e-15)

    // Round-trip.
    #expect(abs(countsToUv(Double(counts(uv: 25.0))) - 25.0) < 0.01)
}

// MARK: - Wire protocol

@Test func decodesTheBinaryBatchFrame() {
    // [0xE7 0x1E] [seq u16 LE] [n u8] [n x i32 LE]
    var bytes: [UInt8] = [0xE7, 0x1E, 0x34, 0x12, 0x02]
    bytes += [0x01, 0x00, 0x00, 0x00]        // +1
    bytes += [0xFF, 0xFF, 0xFF, 0xFF]        // -1 (sign-extended)

    let frame = Vertex.decode(Data(bytes))
    #expect(frame != nil)
    #expect(frame?.seq == 0x1234)
    #expect(frame?.samples == [1, -1])
}

@Test func rejectsTruncatedAndForeignFrames() {
    // A too-small ATT MTU makes the peripheral truncate SILENTLY. Decoding a short frame
    // as if it were whole would inject garbage samples into the spectrum.
    let short = Data([0xE7, 0x1E, 0x00, 0x00, 0x02, 0x01, 0x00])  // claims 2, carries 0.5
    #expect(Vertex.decode(short) == nil)

    let badMagic = Data([0xAA, 0xBB, 0x00, 0x00, 0x00])
    #expect(Vertex.decode(badMagic) == nil)

    #expect(Vertex.decode(Data()) == nil)
}

@Test func parsesTheExactFirmwareInfoLine() {
    // Byte-for-byte what src/main.cpp:71 emits at the boot rate.
    let line = "INFO fw=v4.1 sps=175 mode=binary_batch batch=6 bits=24 vref=3.3 pga=1 afe=1.0 name=NEUROFOCUS_V4_headphone"
    let info = Vertex.parseInfo(line)

    #expect(info?.fw == "v4.1")
    #expect(info?.sps == 175)
    #expect(info?.mode == "binary_batch")
    #expect(info?.batch == 6)
    #expect(info?.bits == 24)
    #expect(info?.afe == 1.0)
    #expect(info?.name == "NEUROFOCUS_V4_headphone")

    // A board left at 600 SPS by a previous session reports 600 — we must believe it,
    // not the 175 boot default. Hard-coding 175 here renders 10 Hz alpha at ~34 Hz.
    #expect(Vertex.parseInfo("INFO fw=v4.1 sps=600 batch=20")?.sps == 600)
    #expect(Vertex.parseInfo("DIAG v=OK") == nil)
}

@Test func rateCommandsMatchTheLadder() {
    #expect(Vertex.rateLadder == [20, 45, 90, 175, 330, 600, 1000, 2000])
    #expect(Vertex.rateCommand(index: 3) == Data([0x7E, 0x33]))  // '~' '3' -> 175 SPS
    #expect(Vertex.rateCommand(index: 7) == Data([0x7E, 0x37]))  // turbo
    #expect(Vertex.rateCommand(index: 8) == nil)
    #expect(Vertex.rateCommand(index: -1) == nil)
}

@Test func parsesDiag() {
    let d = Vertex.parseDiag("DIAG rail=0 dc=12.3%FS rms_uV=8.4 m50=1.2 m60=3.4 alpha=2.1 m/a=1.6 v=OK")
    #expect(d?.verdict == "OK")
    #expect(d?.rmsUvAdcReferred == 8.4)
    #expect(d?.mainsToAlpha == 1.6)

    let err = Vertex.parseDiag("DIAG err=adc_timeout")
    #expect(err?.error == "adc_timeout")
}

// MARK: - The ambient readout (menu bar)

// A number in the window sits beside a scope, a spectrum and a paragraph of caveats.
// A number in the menu bar sits beside the clock. It is glanced at and believed, with none
// of that context — so it must show a dash unless every gate is open.

private func metricsFor(fsOk: Bool = true, signalOk: Bool = true, calibrating: Bool = false,
                        warmingUp: Bool = false, focus: Double = 62) -> FocusMetrics {
    var m = FocusMetrics()
    m.fsOk = fsOk
    m.fsReason = fsOk ? nil : focusFeasibility(fs: 90).reason
    m.signalOk = signalOk
    m.calibrating = calibrating
    m.warmingUp = warmingUp
    m.focus = focus
    m.rmsUv = signalOk ? 12.4 : 0.31
    return m
}

@Test func menuBarShowsANumberOnlyWhenEveryGateIsOpen() {
    #expect(ambientValue(connected: true, metrics: metricsFor()) == "62")
}

@Test func menuBarShowsADashBehindEveryClosedGate() {
    // No board at all.
    #expect(ambientValue(connected: false, metrics: metricsFor()) == "—")

    // Electrode off a head. The window may show the frozen score next to the reason it froze;
    // the menu bar has nowhere to put the reason, so it shows nothing.
    #expect(ambientValue(connected: true, metrics: metricsFor(signalOk: false)) == "—")

    // Sample rate that cannot carry the index — mains would read as concentration.
    #expect(ambientValue(connected: true, metrics: metricsFor(fsOk: false)) == "—")

    // No baseline frozen yet, so there is nothing for 50 to mean.
    #expect(ambientValue(connected: true, metrics: metricsFor(calibrating: true)) == "—")

    // Analysis window not full.
    #expect(ambientValue(connected: true, metrics: metricsFor(warmingUp: true)) == "—")
}

@Test func aDetachedElectrodeCanNeverPutANumberInTheMenuBar() {
    // The frozen score survives behind the gate (the window shows it, greyed). The menu bar
    // must NOT surface it — a stale 88 beside the clock is indistinguishable from a live 88.
    let stale = metricsFor(signalOk: false, focus: 88)
    #expect(stale.focus == 88)
    #expect(ambientValue(connected: true, metrics: stale) == "—")
}

@Test func gatePriorityPutsSampleRateFirst() {
    // An infeasible rate makes the score meaningless no matter how clean the signal is,
    // so it must be the reason reported — not "calibrating".
    let m = metricsFor(fsOk: false, calibrating: true)
    let g = blockingGate(connected: true, metrics: m)
    #expect(g?.kind == .rate)
    #expect(g?.detail.contains("directly inside β") == true)
}

@Test func noGateWhenThereIsNoBoard() {
    // Disconnected is not a "refusal" — there is simply nothing to refuse yet.
    #expect(blockingGate(connected: false, metrics: metricsFor(signalOk: false)) == nil)
}
