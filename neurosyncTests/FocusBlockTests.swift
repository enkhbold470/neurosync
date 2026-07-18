//
//  FocusBlockTests.swift
//  neurosyncTests
//
//  The Focus Block and its drift intervention. Pure — no radio, no Dock, no speaker, no clock.
//
//  These pin the four honesty guarantees the feature exists to hold. Each corresponds to a way the
//  loop could quietly start lying: firing a nudge on no signal, firing outside a block, nagging in a
//  storm, or counting a withheld second as focus.
//

import Testing
@testable import neurosync

// MARK: - Helpers

/// The gated, smoothed state stream the model feeds the detector, one step per second.
/// `driftStep` is the exact function `VertexModel.blockStep` calls, so this drives the real path.
private func run(_ d: inout DriftIntervention, blockActive: Bool, state: BrainState, seconds: Int) -> Int {
    var fires = 0
    for _ in 0..<seconds where driftStep(&d, blockActive: blockActive, state: state, dt: 1) {
        fires += 1
    }
    return fires
}

// MARK: - 1. No nudge behind a closed gate

@Test func noNudgeFiresWhenTheGateIsClosed() {
    // A closed gate — no biosignal, an indefensible sample rate, or still calibrating — resolves to
    // `.withheld` (resolveState: `guard m.trustworthy else { return .withheld }`). The model feeds
    // exactly that resolved state, so feeding `.withheld` here IS the gate-closed case. Hold it far
    // past the dwell: nothing may fire.
    var d = DriftIntervention(driftDwellSec: 20, debounceSec: 120)
    let fires = run(&d, blockActive: true, state: .withheld, seconds: 600)
    #expect(fires == 0)
    #expect(d.nudges == 0)
}

// MARK: - 2. No nudge outside a block

@Test func noNudgeFiresWhenNoBlockIsActive() {
    // Even a long, clean daydream cannot fire a nudge if no block is running — `driftStep` refuses to
    // advance the detector. Drift is only meaningful against a block you *declared* you'd focus in.
    var d = DriftIntervention(driftDwellSec: 20, debounceSec: 120)
    let fires = run(&d, blockActive: false, state: .daydream, seconds: 600)
    #expect(fires == 0)
    #expect(d.nudges == 0)
}

@Test @MainActor func aFreshModelHasNoBlockAndNoCatches() {
    let m = VertexModel()
    #expect(m.blockActive == false)
    #expect(m.blockDriftCatches == 0)
    #expect(m.blockProgress == nil)
    #expect(m.driftAlert == false)
}

// MARK: - 3. The debounce holds

@Test func aSustainedDaydreamFiresOnceThenHoldsForTheDebounce() {
    // The point of the debounce: a sustained drift is ONE cue, not a storm. With D=20 and M=120, a
    // 100 s unbroken daydream may fire exactly once (at t≈20). The second could not come before
    // t=140. Without the debounce this would fire ~80 times.
    var d = DriftIntervention(driftDwellSec: 20, debounceSec: 120)
    let fires = run(&d, blockActive: true, state: .daydream, seconds: 100)
    #expect(fires == 1)
    #expect(d.nudges == 1)
}

@Test func theDebounceSpacesRepeatedNudgesAcrossALongSlump() {
    // A very long slump: fires at 20, 140, 260 — one per debounce window, never more.
    var d = DriftIntervention(driftDwellSec: 20, debounceSec: 120)
    let fires = run(&d, blockActive: true, state: .daydream, seconds: 300)
    #expect(fires == 3)
}

@Test func aDriftShorterThanTheDwellNeverFires() {
    // 15 s of daydream, then out of it. Under the 20 s dwell — a glance out the window, not a slump.
    var d = DriftIntervention(driftDwellSec: 20, debounceSec: 120)
    var fires = run(&d, blockActive: true, state: .daydream, seconds: 15)
    fires += run(&d, blockActive: true, state: .focused, seconds: 30)
    #expect(fires == 0)
}

@Test func leavingDaydreamResetsTheDwell() {
    // Dwell must be CONTINUOUS. 15 s daydream, back to focus, then 15 s daydream again = two sub-dwell
    // stretches, not one 30 s dwell. Neither reaches 20 s, so nothing fires.
    var d = DriftIntervention(driftDwellSec: 20, debounceSec: 120)
    var fires = run(&d, blockActive: true, state: .daydream, seconds: 15)
    fires += run(&d, blockActive: true, state: .focused, seconds: 10)
    fires += run(&d, blockActive: true, state: .daydream, seconds: 15)
    #expect(fires == 0)
}

// MARK: - 4. The recap never counts a withheld second as focus

@Test func recapNeverCountsAWithheldEpochAsFocus() {
    // 100 focused seconds, 50 withheld interleaved, 50 calm. Only the 100 focused may be counted.
    var eps: [Epoch] = []
    for i in 0..<200 {
        let state: BrainState
        switch i % 4 {
        case 0, 1: state = .focused     // 100
        case 2:    state = .withheld    // 50
        default:   state = .calm        // 50
        }
        eps.append(epoch(t: Double(i), state: state))
    }

    let r = recap(epochs: eps, driftCatches: 2)
    #expect(r.focusedSeconds == 100)
    #expect(r.withheldSeconds == 50)
    #expect(r.totalSeconds == 200)
    #expect(r.driftCatches == 2)
    // Coverage counts withheld out of the denominator, never as focus. 150/200.
    #expect(abs(r.coverage - 0.75) < 1e-9)
    // Focus was never inflated by the 50 withheld or 50 calm seconds.
    #expect(r.minutesFocused == 100.0 / 60.0)
}

@Test func aWithheldSecondBreaksTheLongestFocusedStretch() {
    // 40 focused, one withheld, 40 focused. That is NOT an 81 s stretch — the gap is not bridged.
    var eps = (0..<40).map { epoch(t: Double($0), state: .focused) }
    eps.append(epoch(t: 40, state: .withheld))
    eps += (41..<81).map { epoch(t: Double($0), state: .focused) }

    let r = recap(epochs: eps, driftCatches: 0)
    #expect(r.longestFocusedStretchSec == 40, "the withheld second was bridged — stretch must break")
    #expect(r.focusedSeconds == 80)
    #expect(r.withheldSeconds == 1)
}

@Test func anAllWithheldBlockReportsNoFocusAndZeroCoverage() {
    let eps = (0..<120).map { epoch(t: Double($0), state: .withheld) }
    let r = recap(epochs: eps, driftCatches: 0)
    #expect(r.focusedSeconds == 0)
    #expect(r.minutesFocused == 0)
    #expect(r.longestFocusedStretchSec == 0)
    #expect(r.coverage == 0)
}

// MARK: - Epoch fixture

/// A minimal epoch carrying a resolved state. A withheld state gets a null score, as the recorder
/// writes it; everything else gets a placeholder score the recap does not read.
private func epoch(t: Double, state: BrainState) -> Epoch {
    let withheld = state == .withheld
    return Epoch(
        t: t,
        focus: withheld ? nil : 70,
        calm: withheld ? nil : 30,
        clench: withheld ? nil : 10,
        engagement: 1,
        bands: [:],
        alphaPeak: nil,
        rmsUv: withheld ? 0.4 : 12,
        signalOk: !withheld,
        fsOk: true,
        calibrating: false,
        state: state
    )
}
