//
//  FocusBlockTests.swift
//  neurosyncTests
//
//  The Focus Block and its two drift interventions. Pure — no radio, no Dock, no speaker, no clock.
//
//  These pin the honesty guarantees the feature exists to hold. Each corresponds to a way the loop
//  could quietly start lying:
//
//    EEG tier   — firing a nudge on no signal, firing outside a block, nagging in a storm, or
//                 counting a withheld second as focus.
//    App tier   — firing on an unrecognised app, nagging on a brief blip, or nagging while on task.
//    The wall   — showing a focus NUMBER when there was no headset. `BlockRecap.brain` is Optional;
//                 with no epochs it is nil, so there is nothing for the UI to render.
//

import Testing
@testable import neurosync

// MARK: - Helpers

/// The gated, smoothed state stream the model feeds the EEG detector, one step per second.
/// `driftStep` is the exact function `VertexModel.blockStep` calls, so this drives the real path.
private func run(_ d: inout DriftIntervention, blockActive: Bool, state: BrainState, seconds: Int) -> Int {
    var fires = 0
    for _ in 0..<seconds where driftStep(&d, blockActive: blockActive, state: state, dt: 1) {
        fires += 1
    }
    return fires
}

/// The measured app-context stream the model feeds the app detector, one step per second.
/// `appDriftStep` is the exact function `VertexModel.blockStep` calls.
private func runApp(_ d: inout AppDriftDetector, blockActive: Bool, context: WorkContext, seconds: Int) -> Int {
    var fires = 0
    for _ in 0..<seconds where appDriftStep(&d, blockActive: blockActive, context: context, dt: 1) {
        fires += 1
    }
    return fires
}

// MARK: - EEG tier · 1. No nudge behind a closed gate

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

// MARK: - EEG tier · 2. No nudge outside a block

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

// MARK: - EEG tier · 3. The debounce holds

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

// MARK: - App tier · the headset-free drift signal

@Test func workContextClassifiesAppsHonestly() {
    // Effortful apps are on-task; clearly non-work apps (comms, any browser) are away; anything
    // unrecognised is neutral — we don't know, so we say nothing.
    #expect(workContext(for: .coding) == .onTask)
    #expect(workContext(for: .design) == .onTask)
    #expect(workContext(for: .meeting) == .onTask)
    #expect(workContext(for: .onCall) == .onTask)
    #expect(workContext(for: .reading) == .onTask)
    #expect(workContext(for: .comms) == .away)
    #expect(workContext(for: .browsing) == .away)
    #expect(workContext(for: .unknown) == .neutral)
    #expect(workContext(for: .breakTime) == .neutral)
    #expect(workContext(for: .walk) == .neutral)
}

@Test func appDriftFiresOnSustainedAwayDwellAndNotBefore() {
    // D_app = 45 s away before a single gentle nudge. 44 s is under the dwell — a quick Slack reply,
    // not a slip.
    var d = AppDriftDetector(awayDwellSec: 45, debounceSec: 120)
    #expect(runApp(&d, blockActive: true, context: .away, seconds: 44) == 0)

    var d2 = AppDriftDetector(awayDwellSec: 45, debounceSec: 120)
    #expect(runApp(&d2, blockActive: true, context: .away, seconds: 60) == 1)
}

@Test func appDriftDebounceHoldsUnderASustainedSlip() {
    // A long slip is ONE cue per window, never a storm: fires at 45, 165, 285.
    var d = AppDriftDetector(awayDwellSec: 45, debounceSec: 120)
    let fires = runApp(&d, blockActive: true, context: .away, seconds: 300)
    #expect(fires == 3)
}

@Test func stayingOnTaskNeverFiresAppDrift() {
    // In your work app the whole time: no nudge, ever. Switching between two effortful apps
    // (Xcode → Figma) is two on-task contexts, so it is not a slip either.
    var d = AppDriftDetector(awayDwellSec: 45, debounceSec: 120)
    let fires = runApp(&d, blockActive: true, context: .onTask, seconds: 600)
    #expect(fires == 0)
}

@Test func neutralAppNeitherFiresNorRescues() {
    // An unrecognised app is neutral: alone it never nudges...
    var d = AppDriftDetector(awayDwellSec: 45, debounceSec: 120)
    #expect(runApp(&d, blockActive: true, context: .neutral, seconds: 600) == 0)

    // ...and a brief neutral blip mid-slip does NOT reset the away dwell (it holds), so a real slump
    // still earns its one nudge: 44 s away, 10 s neutral (held), 1 s away = 45 s away → fires once.
    var d2 = AppDriftDetector(awayDwellSec: 45, debounceSec: 120)
    var fires = runApp(&d2, blockActive: true, context: .away, seconds: 44)
    fires += runApp(&d2, blockActive: true, context: .neutral, seconds: 10)
    fires += runApp(&d2, blockActive: true, context: .away, seconds: 1)
    #expect(fires == 1)
}

@Test func comingBackOnTaskResetsTheAwayDwell() {
    // 44 s away, back on task (resets), 44 s away again = two sub-dwell slips, not one. Nothing fires.
    var d = AppDriftDetector(awayDwellSec: 45, debounceSec: 120)
    var fires = runApp(&d, blockActive: true, context: .away, seconds: 44)
    fires += runApp(&d, blockActive: true, context: .onTask, seconds: 10)
    fires += runApp(&d, blockActive: true, context: .away, seconds: 44)
    #expect(fires == 0)
}

@Test func noAppNudgeOutsideABlock() {
    // Away all day is not a slip if you never declared a block. `appDriftStep` refuses to advance.
    var d = AppDriftDetector(awayDwellSec: 45, debounceSec: 120)
    #expect(runApp(&d, blockActive: false, context: .away, seconds: 600) == 0)
}

// MARK: - Behavioural tally (measured facts, always present)

@Test func behaviourTallyCountsOnTaskAwayAndNeutral() {
    var t = BehaviorTally()
    for _ in 0..<120 { t.add(kind: .coding, label: "Xcode", bundleId: "com.apple.dt.Xcode") }   // on task
    for _ in 0..<30 { t.add(kind: .comms, label: "Slack", bundleId: "com.tinyspeck.slackmacgap") } // away
    for _ in 0..<10 { t.add(kind: .unknown, label: "Mystery", bundleId: "com.x.y") }              // neutral

    let r = t.recap(slips: 1)
    #expect(r.totalSeconds == 160)
    #expect(r.onTaskSeconds == 120)
    #expect(r.awaySeconds == 30)
    #expect(r.slips == 1)
    // No focus field exists to check — that is the point.
    #expect(r.topApps.first?.label == "Xcode")
    #expect(r.topApps.first?.seconds == 120)
}

@Test func onTaskStretchBreaksOnAwayAndOnNeutral() {
    // The longest on-task stretch is not bridged across an away second...
    var t1 = BehaviorTally()
    for _ in 0..<40 { t1.add(kind: .coding, label: "Xcode", bundleId: "x") }
    t1.add(kind: .comms, label: "Slack", bundleId: "s")
    for _ in 0..<40 { t1.add(kind: .coding, label: "Xcode", bundleId: "x") }
    #expect(t1.recap(slips: 0).longestOnTaskStretchSec == 40)

    // ...nor across an unknown (neutral) second — on-task means recognised effortful work.
    var t2 = BehaviorTally()
    for _ in 0..<40 { t2.add(kind: .coding, label: "Xcode", bundleId: "x") }
    t2.add(kind: .unknown, label: "Mystery", bundleId: "m")
    for _ in 0..<40 { t2.add(kind: .coding, label: "Xcode", bundleId: "x") }
    #expect(t2.recap(slips: 0).longestOnTaskStretchSec == 40)
}

// MARK: - The wall · no brain number without a brain

@Test func headsetFreeBlockHasNoBrainHalfAndNoFocusNumber() {
    // With no epochs there is no headset, so `brainRecap` is nil and `BlockRecap.brain` is nil. The
    // behavioural half is fully populated. The UI literally has no focus number to render.
    #expect(brainRecap(epochs: []) == nil)

    var t = BehaviorTally()
    for _ in 0..<300 { t.add(kind: .coding, label: "Xcode", bundleId: "com.apple.dt.Xcode") }
    let headsetFree = makeRecap(behavior: t.recap(slips: 2), epochs: [], driftCatches: 2)

    #expect(headsetFree.brain == nil)
    #expect(headsetFree.hadHeadset == false)
    #expect(headsetFree.behavior.onTaskSeconds == 300)
    #expect(headsetFree.driftCatches == 2)
}

@Test func makeRecapAddsTheBrainHalfOnlyWhenEpochsExist() {
    var t = BehaviorTally()
    for _ in 0..<60 { t.add(kind: .coding, label: "Xcode", bundleId: "com.apple.dt.Xcode") }
    let behavior = t.recap(slips: 0)

    let eps = (0..<60).map { epoch(t: Double($0), state: .focused) }
    let withHeadset = makeRecap(behavior: behavior, epochs: eps, driftCatches: 0)
    #expect(withHeadset.hadHeadset == true)
    #expect(withHeadset.brain?.focusedSeconds == 60)
    #expect(withHeadset.behavior.onTaskSeconds == 60)   // both halves coexist, in separate fields
}

// MARK: - Brain half · never counts a withheld second as focus

@Test func brainRecapNeverCountsAWithheldEpochAsFocus() {
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

    let r = brainRecap(epochs: eps)!
    #expect(r.focusedSeconds == 100)
    #expect(r.withheldSeconds == 50)
    #expect(r.brainSeconds == 200)
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

    let r = brainRecap(epochs: eps)!
    #expect(r.longestFocusedStretchSec == 40, "the withheld second was bridged — stretch must break")
    #expect(r.focusedSeconds == 80)
    #expect(r.withheldSeconds == 1)
}

@Test func anAllWithheldHeadsetBlockReportsNoFocusAndZeroCoverageButStillHasABrainHalf() {
    // A headset that was on but gated the whole time: the brain half EXISTS (a board was present) and
    // honestly reports zero focus and zero coverage — it is not nil, because this is not headset-free.
    let eps = (0..<120).map { epoch(t: Double($0), state: .withheld) }
    let r = brainRecap(epochs: eps)
    #expect(r != nil)
    #expect(r?.focusedSeconds == 0)
    #expect(r?.minutesFocused == 0)
    #expect(r?.longestFocusedStretchSec == 0)
    #expect(r?.coverage == 0)
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
