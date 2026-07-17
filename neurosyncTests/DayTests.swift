//
//  DayTests.swift
//  neurosyncTests
//
//  The Day view's load-bearing claims, pinned.
//
//  Most of these are not "does the code work" tests. They are "does the code still refuse to lie"
//  tests — the gaps stay gaps, the clenched jaw is not counted as focus, the synthetic data cannot
//  reach a surface that would let it pass for a brain. Those are the properties that make this
//  feature shippable at all, and they are exactly the ones a future refactor would quietly break.
//

import Foundation
import Testing

@testable import neurosync

// MARK: - Helpers

/// Run a profile through the REAL engine and return what the DSP makes of it.
///
/// Note what this helper cannot do: set a score. It sets a spectrum and reads back whatever
/// Focus.swift computes. Every expectation below is therefore a claim about the DSP, not about the
/// generator's intentions.
@MainActor
private func metricsFor(
    _ profile: SynthProfile,
    fs: Double = 330,
    seconds: Double = 90,
    calibrateWith: SynthProfile = .baseline,
    seed: UInt64 = 0xC0FFEE
) -> FocusMetrics {
    // ONE continuous stream: 40 s of baseline to freeze E0, then the profile under test.
    //
    // Generating the two halves as separate calls looks equivalent and is not — the oscillator
    // phases and the pink filter's state would restart at the seam, and the discontinuity lands in
    // the engine's 3 s analysis window as a transient. Every score afterwards is relative to E0, so
    // a seam that perturbs the calibration window biases the entire test.
    let counts = synthesizeCounts(
        blocks: [
            SynthBlock(startSec: 0, durationSec: 40, profile: calibrateWith, rampSec: 0),
            SynthBlock(startSec: 40, durationSec: seconds, profile: profile, rampSec: 10)
        ],
        fs: fs, durationSec: 40 + seconds, seed: seed
    )

    let engine = FocusEngine(fs: fs)
    for c in counts { engine.push(counts: c) }
    return engine.metrics
}

// MARK: - The generator produces what it claims to

@Test @MainActor
func baselineProfileScoresAtItsOwnBaseline() {
    let m = metricsFor(.baseline)
    #expect(!m.calibrating)
    #expect(m.signalOk)
    // 50 IS the baseline. Held at the calibration spectrum, the score must sit on it.
    #expect(abs(m.focus - 50) < 12, "baseline scored \(m.focus), expected ~50")
}

@Test @MainActor
func focusedProfileScoresAboveTheFlowLine() {
    let m = metricsFor(.focused)
    #expect(m.focus >= flowThreshold, "focused scored \(m.focus), expected >= \(flowThreshold)")
    #expect(resolveState(m, effortful: true) == .focused)
}

@Test @MainActor
func disengagedProfileFallsWellUnderBaseline() {
    let m = metricsFor(.disengaged)
    #expect(m.focus < disengagedThreshold, "disengaged scored \(m.focus), expected < \(disengagedThreshold)")
    #expect(m.calm >= alphaRisenThreshold, "alpha did not rise: calm \(m.calm)")
}

/// The same spectrum, two states. This is the honest core of the whole feature: a daydream and a
/// rest are indistinguishable in the signal, and only the calendar tells them apart.
@Test @MainActor
func daydreamAndCalmAreTheSameSpectrumAndDifferOnlyByContext() {
    let m = metricsFor(.disengaged)
    #expect(resolveState(m, effortful: true) == .daydream)
    #expect(resolveState(m, effortful: false) == .calm)
}

// MARK: - The instrument refuses to lie

/// The one that matters most. A clenched jaw drives EMG into beta — the focus NUMERATOR — so the
/// raw score goes UP. If the clench gate ever stops firing, this app starts reporting a tense jaw
/// as concentration, which is the single most damaging thing it could do.
@Test @MainActor
func clenchedJawIsNeverReportedAsFocus() {
    let m = metricsFor(.clenching)

    #expect(m.clench >= clenchThreshold, "clench read \(m.clench), expected >= \(clenchThreshold)")

    // Prove the trap is real: the raw engagement index really did climb. It is the gate, not the
    // absence of contamination, that saves us here.
    #expect(m.focus > 50, "EMG should INFLATE the raw score — if it did not, this test proves nothing")

    #expect(resolveState(m, effortful: true) == .clenched,
            "focus was \(m.focus) with clench \(m.clench) — reported as focus, not contamination")
}

@Test @MainActor
func talkingInAMeetingContaminatesRatherThanImpresses() {
    let m = metricsFor(.talking)
    #expect(resolveState(m, effortful: true) == .clenched)
}

/// The 90 SPS session in the synthetic day. 60 Hz mains folds to 30 Hz — dead centre of beta — and
/// cannot be notched. Every second must be withheld no matter how clean the trace looks.
@Test @MainActor
func infeasibleSampleRateWithholdsEverySecond() {
    let m = metricsFor(.focused, fs: 90)
    #expect(!m.fsOk)
    #expect(resolveState(m, effortful: true) == .withheld)
}

/// A trustworthy signal whose instantaneous state merely flickers must NEVER be labelled withheld.
/// Withheld means "no signal", not "the smoother couldn't decide" — see StateSmoother.
@Test
func aVariableButTrustworthySignalIsNeverLabelledWithheld() {
    var sm = StateSmoother(dwell: minimumDwellSec)
    // Prime with a clean second so we leave the initial withheld.
    _ = sm.step(.neutral, dt: 1)
    // Now flicker between two real states every second for two minutes — neither ever holds 15 s.
    var sawWithheld = false
    for i in 0..<120 {
        let label = sm.step(i % 2 == 0 ? .focused : .neutral, dt: 1)
        if label == .withheld { sawWithheld = true }
    }
    #expect(!sawWithheld, "a flickering but trustworthy signal was labelled withheld — the smoother stuck")
}

/// Signal loss still takes effect immediately, with no dwell — the safety-critical direction.
@Test
func losingSignalIsLabelledWithheldImmediately() {
    var sm = StateSmoother(dwell: minimumDwellSec)
    for _ in 0..<30 { _ = sm.step(.focused, dt: 1) }
    #expect(sm.step(.focused, dt: 1) == .focused)
    // Electrode falls off: withheld on the very next second, not 15 s later.
    #expect(sm.step(.withheld, dt: 1) == .withheld)
}

@Test @MainActor
func electrodeOffCollapsesToWithheldNotToAPerfectScore() {
    let fs = 330.0
    // One continuous stream: calibrate, run, then the pad comes off and stays off.
    let counts = synthesizeCounts(
        blocks: [
            SynthBlock(startSec: 0, durationSec: 50, profile: .baseline, rampSec: 0),
            SynthBlock(startSec: 50, durationSec: 40, profile: .off, rampSec: 0)
        ],
        fs: fs, durationSec: 90, seed: 1)

    let engine = FocusEngine(fs: fs)

    // The guarantee is not "the score never changes after time T". It is "the score never changes
    // once SIGNAL IS LOST". So track the last score seen while the gate was open, and prove it does
    // not move on any update where the gate is closed. The window takes ~3 s to drain the last good
    // samples after the pad lifts — during that drain the score may still move, legitimately.
    var lastGoodFocus = 0.0
    var frozenAt: Double?
    var sawWithheld = false

    for c in counts {
        engine.push(counts: c)
        let m = engine.metrics
        if m.signalOk {
            lastGoodFocus = m.focus
            frozenAt = nil
        } else if !m.calibrating {
            sawWithheld = true
            // First closed-gate update after signal loss: latch the value it froze at.
            if frozenAt == nil { frozenAt = m.focus }
            // It must NOT spike to 100, and it must NOT drift — it holds the last good value.
            #expect(abs(m.focus - frozenAt!) < 0.001, "score moved while the electrode was off")
            #expect(abs(m.focus - lastGoodFocus) < 0.001,
                    "frozen score \(m.focus) is not the last good score \(lastGoodFocus)")
        }
    }

    let final = engine.metrics
    #expect(sawWithheld, "signal was never lost — the test never exercised the gate")
    #expect(!final.signalOk, "RMS \(final.rmsUv) µV — the detached-electrode gate did not close")
    #expect(resolveState(final, effortful: true) == .withheld)
    #expect(final.focus < 90, "a detached electrode read as near-perfect focus: \(final.focus)")
}

// MARK: - Gaps stay gaps

@Test
func withheldSecondsBreakTheFocusLineRatherThanBeingBridged() {
    let start = Date(timeIntervalSince1970: 0)
    func e(_ t: Double, _ f: Double?, ok: Bool) -> Epoch {
        Epoch(t: t, focus: f, calm: f, clench: 10, engagement: 1, bands: [:],
              alphaPeak: nil, rmsUv: ok ? 12 : 0.4,
              signalOk: ok, fsOk: true, calibrating: false,
              state: ok ? .focused : .withheld)
    }
    // 5 good, 5 dead, 5 good.
    let eps = (0..<5).map { e(Double($0), 70, ok: true) }
        + (5..<10).map { e(Double($0), nil, ok: false) }
        + (10..<15).map { e(Double($0), 70, ok: true) }

    let s = SessionRecord(
        startedAt: start, endedAt: start.addingTimeInterval(15),
        device: DeviceInfo(name: "t", sps: 330), baseline: nil,
        epochs: eps, activities: [], markers: [])
    let day = rollUp(sessions: [s], markers: [], date: start)

    let lines = focusPolylines(day, everyNth: 1)
    #expect(lines.count == 2, "the dropout was bridged — \(lines.count) polyline(s), expected 2")
}

@Test
func aWithheldSecondBreaksAFlowRun() {
    let start = Date(timeIntervalSince1970: 0)
    func e(_ t: Double, _ st: BrainState) -> Epoch {
        Epoch(t: t, focus: st == .withheld ? nil : 70, calm: 30, clench: 10, engagement: 1,
              bands: [:], alphaPeak: nil, rmsUv: 12,
              signalOk: st != .withheld, fsOk: true, calibrating: false, state: st)
    }
    // 600 focused, one dead second, 600 focused. That is NOT a 20-minute flow block.
    var eps = (0..<600).map { e(Double($0), .focused) }
    eps.append(e(600, .withheld))
    eps += (601..<1201).map { e(Double($0), .focused) }

    let span = ActivitySpan(kind: .coding, label: "Claude coding",
                            start: start, end: start.addingTimeInterval(1201),
                            source: .appWatch, bundleId: nil)
    let s = SessionRecord(startedAt: start, endedAt: start.addingTimeInterval(1201),
                          device: DeviceInfo(name: "t", sps: 330), baseline: nil,
                          epochs: eps, activities: [span], markers: [])

    let seg = segment(s, span: span)
    #expect(seg.longestFlowSec == 600, "longest run was \(seg.longestFlowSec)s — the gap was bridged")
}

// MARK: - The wall

@Test
func aDayWithAnySyntheticSessionIsFlaggedSynthetic() {
    let s = SessionRecord(
        synthetic: true, syntheticNote: syntheticNote,
        startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 60),
        device: DeviceInfo(name: "t", sps: 330), baseline: nil,
        epochs: [], activities: [], markers: [])

    let day = rollUp(sessions: [s], markers: [], date: s.startedAt)
    #expect(day.synthetic, "a day containing a synthetic session must be flagged synthetic")
}

@Test @MainActor
func storeRefusesASyntheticRecordWithNoProvenance() throws {
    let store = Store()
    try #require(store.hasLocation, "no data folder granted — cannot exercise the store")

    // synthetic: true with no note is how a generated record would sneak in unlabelled.
    let sneaky = SessionRecord(
        synthetic: true, syntheticNote: nil,
        startedAt: Date(), endedAt: Date(),
        device: DeviceInfo(name: "t", sps: 330), baseline: nil,
        epochs: [], activities: [], markers: [])

    #expect(throws: StoreError.self) { try store.write(sneaky) }
}

/// The menu bar is the most dangerous surface in the app: a number there sits beside the clock, with
/// nowhere to put a caveat. It must read from the live link and NOTHING else — no store, no day, no
/// persisted record, synthetic or otherwise.
@Test @MainActor
func menuBarNeverReadsPersistedData() {
    let m = VertexModel()
    // Not connected: no board, no score, regardless of what is on disk.
    #expect(m.menuBarValue == "—")
    #expect(m.menuBarState == "NO DEVICE")
}

// MARK: - Findings

@Test @MainActor
func everyFindingCarriesItsCaveat() {
    let days = syntheticDayFixture()
    for day in days {
        for f in day.findings {
            #expect(!f.caveat.isEmpty, "finding without a caveat: \(f.headline)")
        }
    }
}

@Test
func aBlockWithTooLittleCoverageGetsNoVerdict() {
    let start = Date(timeIntervalSince1970: 0)
    // 600 s, 90% of it withheld.
    let eps = (0..<600).map { i -> Epoch in
        let ok = i < 60
        return Epoch(t: Double(i), focus: ok ? 70 : nil, calm: ok ? 30 : nil,
                     clench: ok ? 10 : nil, engagement: 1, bands: [:], alphaPeak: nil,
                     rmsUv: ok ? 12 : 0.4, signalOk: ok, fsOk: true, calibrating: false,
                     state: ok ? .focused : .withheld)
    }
    let span = ActivitySpan(kind: .coding, label: "Claude coding", start: start,
                            end: start.addingTimeInterval(600), source: .appWatch, bundleId: nil)
    let s = SessionRecord(startedAt: start, endedAt: start.addingTimeInterval(600),
                          device: DeviceInfo(name: "t", sps: 330), baseline: nil,
                          epochs: eps, activities: [span], markers: [])

    let seg = segment(s, span: span)
    #expect(!seg.sayable, "coverage \(seg.coverage) — a verdict was allowed on almost no data")

    let day = rollUp(sessions: [s], markers: [], date: start)
    #expect(day.findings.contains { $0.headline.contains("no verdict") },
            "the block was silently dropped instead of refused out loud")
}

// MARK: - Round trip

@Test
func aSessionSurvivesJsonUnchanged() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let s = SessionRecord(
        synthetic: true, syntheticNote: "note",
        startedAt: start, endedAt: start.addingTimeInterval(3),
        device: DeviceInfo(name: "NEUROFOCUS_V4_headphone", sps: 330, firmware: "v4"),
        baseline: BaselineInfo(engagement: 0.56, clench: 0.04, frozenAt: start, reused: false),
        epochs: [
            Epoch(t: 0, focus: nil, calm: nil, clench: nil, engagement: 0.4,
                  bands: ["alpha": 12.5], alphaPeak: nil, rmsUv: 0.3,
                  signalOk: false, fsOk: true, calibrating: false, state: .withheld),
            Epoch(t: 1, focus: 62.5, calm: 30, clench: 44, engagement: 0.9,
                  bands: ["alpha": 12.5], alphaPeak: 10.2, rmsUv: 14,
                  signalOk: true, fsOk: true, calibrating: false, state: .focused)
        ],
        activities: [ActivitySpan(kind: .coding, label: "Claude coding", start: start,
                                  end: start.addingTimeInterval(3), source: .appWatch,
                                  bundleId: "com.anthropic.claude")],
        markers: [Marker(kind: .stressed, at: start, note: "nothing works")])

    let data = try neurosyncEncoder().encode(s)
    let back = try neurosyncDecoder().decode(SessionRecord.self, from: data)
    #expect(back == s)

    // The null must be WRITTEN, not omitted. A reader opening this file cold must see that the
    // instrument declined to answer that second — an absent key could mean anything.
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"focus\" : null"), "withheld focus was omitted instead of written as null")
}

// MARK: - Activity

@Test
func frontmostAppBundlesMapToActivities() {
    #expect(activityForBundle("com.anthropic.claude") == .coding)
    #expect(activityForBundle("com.apple.dt.Xcode") == .coding)
    #expect(activityForBundle("com.figma.Desktop") == .design)
    #expect(activityForBundle("us.zoom.xos") == .meeting)
    #expect(activityForBundle("com.example.nothing") == .unknown)
}

@Test
func calendarEventsClassifyFromTitleAndLocation() {
    #expect(activityForEvent(title: "Standup", location: nil, url: nil) == .meeting)
    #expect(activityForEvent(title: "Sync", location: "https://zoom.us/j/123", url: nil) == .meeting)
    #expect(activityForEvent(title: "On-call rotation", location: nil, url: nil) == .onCall)
    #expect(activityForEvent(title: "Design crit", location: nil, url: nil) == .design)
    #expect(activityForEvent(title: "Lunch", location: nil, url: nil) == .breakTime)
}

/// A glance at Slack must not cut a two-hour coding block into three.
@Test
func aGlanceAtSlackDoesNotShatterACodingBlock() {
    let t0 = Date(timeIntervalSince1970: 0)
    var samples: [(at: Date, kind: ActivityKind, label: String, bundleId: String)] = []
    for i in 0..<720 {   // 60 min at 5 s
        let glance = i >= 360 && i < 364   // 20 s in Slack
        samples.append((
            at: t0.addingTimeInterval(Double(i) * 5),
            kind: glance ? .comms : .coding,
            label: glance ? "Slack" : "Claude",
            bundleId: glance ? "com.tinyspeck.slackmacgap" : "com.anthropic.claude"
        ))
    }
    let spans = coalesce(samples: samples)
    #expect(spans.count == 1, "the glance shattered the block into \(spans.count) spans")
    #expect(spans.first?.kind == .coding)
}

// MARK: - Fixture

/// A SMALL real day, run through the real DSP. Deliberately not `generateSyntheticDays()` — the full
/// two-day script is ~11 hours of signal and, through the hand-rolled FFT in a debug build, takes
/// many minutes. That belongs in the app (backgrounded, opt-in), not in a unit test that should
/// finish in seconds. This exercises the same findings/rollup code on ~7 minutes of signal.
@MainActor
private var cachedFixture: [Day]?

@MainActor
private func syntheticDayFixture() -> [Day] {
    if let cachedFixture { return cachedFixture }

    let fs = 175.0
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    // 40 s calibrate · 2 min focused · 2.5 min disengaged. Enough to fire a sub-baseline finding
    // and a mind-wandering finding inside an effortful block.
    let blocks = [
        SynthBlock(startSec: 0, durationSec: 40, profile: .baseline, rampSec: 0),
        SynthBlock(startSec: 40, durationSec: 120, profile: .focused, rampSec: 15),
        SynthBlock(startSec: 160, durationSec: 220, profile: .disengaged, rampSec: 20)
    ]
    let counts = synthesizeCounts(blocks: blocks, fs: fs, durationSec: 380, seed: 0xF1)

    let span = ActivitySpan(kind: .coding, label: "Claude coding", start: start,
                            end: start.addingTimeInterval(380), source: .appWatch,
                            bundleId: "com.anthropic.claude")
    let rec = SessionRecorder(fs: fs, effortfulAt: { _ in true })
    for c in counts { rec.push(counts: c) }
    let session = rec.finish(
        startedAt: start,
        device: DeviceInfo(name: Vertex.deviceName, sps: Int(fs), firmware: "v4"),
        activities: [span],
        markers: [Marker(kind: .stressed, at: start.addingTimeInterval(300), note: "stuck")],
        synthetic: true, syntheticNote: syntheticNote)

    let day = rollUp(sessions: [session], markers: session.markers, date: start)
    cachedFixture = [day]
    return cachedFixture!
}
