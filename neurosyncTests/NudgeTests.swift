//
//  NudgeTests.swift
//  neurosyncTests
//
//  The crash-out nudge. Pure — no Dock, no radio.
//

import Testing
@testable import neurosync

/// Drive a constant focus for `seconds`, one sample per second.
private func hold(_ n: inout FocusNudge, focus: Double, seconds: Int) {
    for _ in 0..<seconds { _ = n.sample(focus: focus, dt: 1) }
}

@Test func aBriefDipNeverFires() {
    var n = FocusNudge()
    // 10 s under 20 is not a slump — it is a blink or a swallow.
    hold(&n, focus: 15, seconds: 10)
    #expect(n.level == .none)
}

@Test func aSustainedLowScoreSuggestsABreak() {
    var n = FocusNudge()
    hold(&n, focus: 15, seconds: 50)      // < 20 for longer than sustainSec
    #expect(n.level == .breather)
    #expect(n.level.badge == "!")
    #expect(n.level.message?.contains("5-minute") == true)
}

@Test func aSustainedVeryLowScoreSuggestsAWalk() {
    var n = FocusNudge()
    hold(&n, focus: 6, seconds: 50)       // < 10 sustained
    #expect(n.level == .walk)
    #expect(n.level.badge == "!!")
    #expect(n.level.message?.contains("10-minute") == true)
}

@Test func recoveryClearsTheNudge() {
    var n = FocusNudge()
    hold(&n, focus: 8, seconds: 50)
    #expect(n.level == .walk)
    // Climb clearly back above baseline-ish.
    hold(&n, focus: 40, seconds: 3)
    #expect(n.level == .none)
}

@Test func hysteresisHoldsThroughAMildRebound() {
    var n = FocusNudge()
    hold(&n, focus: 15, seconds: 50)
    #expect(n.level == .breather)
    // Rebound to 25 — above the fire line but below the CLEAR line. Must hold, not flicker off.
    hold(&n, focus: 25, seconds: 5)
    #expect(n.level == .breather)
}

@Test func climbingOutOfTheDeepZoneDowngradesWalkToBreather() {
    var n = FocusNudge()
    hold(&n, focus: 6, seconds: 50)
    #expect(n.level == .walk)
    // Now 15: out of the < 10 deep zone, still < 20. Should ease to a break suggestion.
    hold(&n, focus: 15, seconds: 50)
    #expect(n.level == .breather)
}

@Test func resetClearsEverything() {
    var n = FocusNudge()
    hold(&n, focus: 6, seconds: 50)
    #expect(n.level == .walk)
    n.reset()
    #expect(n.level == .none)
    // And it must re-earn the nudge from scratch — one low sample after reset is not enough.
    _ = n.sample(focus: 6, dt: 1)
    #expect(n.level == .none)
}

@Test func levelsAreOrdered() {
    #expect(FocusNudge.Level.none < .breather)
    #expect(FocusNudge.Level.breather < .walk)
}
