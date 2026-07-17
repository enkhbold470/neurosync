//
//  TimelineTests.swift
//  neurosyncTests
//
//  The zoom/pan math and the ruler tick selection, pinned. Pure — no view, no radio.
//

import Foundation
import Testing

@testable import neurosync

private let t0 = Date(timeIntervalSinceReferenceDate: 0)
private func vp(spanHours: Double = 8) -> Viewport {
    Viewport(dayStart: t0, dayEnd: t0.addingTimeInterval(spanHours * 3600))
}

// MARK: - Viewport bounds

@Test func aFreshViewportFitsTheWholeDay() {
    let v = vp(spanHours: 8)
    #expect(v.start == t0)
    #expect(abs(v.span - 8 * 3600) < 0.001)
    #expect(abs(v.coverage - 1) < 0.001)
}

@Test func zoomingInNeverGoesBelowTheSixtySecondFloor() {
    var v = vp()
    for _ in 0..<50 { v = v.zoomed(factor: 4, anchor: 0.5) }
    #expect(v.span == Viewport.minSpan)
}

@Test func zoomingOutNeverExceedsTheWholeDay() {
    var v = vp(spanHours: 6)
    v = v.zoomed(factor: 8, anchor: 0.5)          // zoom in first
    for _ in 0..<50 { v = v.zoomed(factor: 1 / 4, anchor: 0.5) }
    #expect(abs(v.span - v.daySpan) < 0.001)
    #expect(v.start == v.dayStart)
}

@Test func panningCannotEscapeTheDayBounds() {
    var v = vp(spanHours: 4).zoomed(factor: 4, anchor: 0.5)   // 1h window inside 4h day
    v = v.panned(bySeconds: -99_999)                          // yank hard left
    #expect(v.start == v.dayStart)
    v = v.panned(bySeconds: 99_999)                           // yank hard right
    #expect(abs(v.end.timeIntervalSince(v.dayEnd)) < 0.001)
}

// MARK: - Anchored zoom

@Test func zoomKeepsTheAnchoredTimeUnderTheCursor() {
    // 8h day. Put the cursor 1/4 across and zoom in 2×. The time under 1/4 must not move.
    let v = vp(spanHours: 8)
    let anchor = 0.25
    let timeUnderCursorBefore = v.start.addingTimeInterval(v.span * anchor)
    let z = v.zoomed(factor: 2, anchor: anchor)
    let timeUnderCursorAfter = z.start.addingTimeInterval(z.span * anchor)
    #expect(abs(timeUnderCursorAfter.timeIntervalSince(timeUnderCursorBefore)) < 0.5)
    #expect(abs(z.span - v.span / 2) < 0.001)
}

@Test func centeringPutsTheWindowMidpointOnTheTarget() {
    let v = vp(spanHours: 8).zoomed(factor: 8, anchor: 0.5)   // 1h window
    let target = t0.addingTimeInterval(5 * 3600)
    let c = v.centered(on: target)
    let mid = c.start.addingTimeInterval(c.span / 2)
    #expect(abs(mid.timeIntervalSince(target)) < 0.5)
}

@Test func marqueeRangeBecomesTheViewport() {
    let v = vp(spanHours: 8)
    let a = t0.addingTimeInterval(2 * 3600)
    let b = t0.addingTimeInterval(3 * 3600)
    let r = v.ranged(b, a)                        // order-independent
    #expect(r.start == a)
    #expect(abs(r.span - 3600) < 0.001)
}

// MARK: - Ruler ticks

@Test func rulerStepGrowsCoarserAsTheWindowWidens() {
    let w: CGFloat = 1000
    // A 6-hour window at 1000px → coarse steps; a 5-minute window → fine steps.
    let wide = rulerTicks(start: t0, span: 6 * 3600, width: w, epoch: t0)
    let narrow = rulerTicks(start: t0, span: 300, width: w, epoch: t0)
    #expect(!wide.isEmpty && !narrow.isEmpty)

    func minGap(_ ticks: [RulerTick]) -> TimeInterval {
        var smallest = TimeInterval.infinity
        for i in 1..<ticks.count {
            let gap = ticks[i].date.timeIntervalSince(ticks[i - 1].date)
            if gap < smallest { smallest = gap }
        }
        return smallest
    }
    // Wider window ⇒ each tick spans more real time.
    #expect(minGap(wide) > minGap(narrow))
}

@Test func rulerTicksStayAtLeastMinPixelsApart() {
    let w: CGFloat = 900
    let span: TimeInterval = 3 * 3600
    let ticks = rulerTicks(start: t0, span: span, width: w, epoch: t0, minPixels: 76)
    let ax = TimeAxis(start: t0, end: t0.addingTimeInterval(span), width: w)
    let xs = ticks.map { ax.x($0.date) }
    for (a, b) in zip(xs, xs.dropFirst()) {
        #expect(b - a >= 76 - 0.5)
    }
}

@Test func majorTicksAlignToClockBoundaries() {
    // A window that does not start on a round boundary must still produce labelled ticks that do.
    let start = t0.addingTimeInterval(37 * 60 + 13)     // 00:37:13
    let ticks = rulerTicks(start: start, span: 2 * 3600, width: 1000, epoch: t0)
    let majors = ticks.filter(\.major)
    #expect(!majors.isEmpty)
    for m in majors {
        // Major ticks land on a whole number of minutes past the epoch.
        let secs = m.date.timeIntervalSince(t0)
        #expect(abs(secs.truncatingRemainder(dividingBy: 60)) < 0.5)
    }
}

@Test func spanLabelReadsHumanely() {
    #expect(spanLabel(45) == "45s")
    #expect(spanLabel(8 * 60 + 30) == "8m 30s")
    #expect(spanLabel(2 * 3600 + 15 * 60) == "2h 15m")
    #expect(spanLabel(3600) == "1h")
}

// MARK: - Scrubber honesty

@Test func theScrubberFindsTheEpochUnderAnInstant() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var eps: [Epoch] = []
    for i in 0..<120 {
        let good = i < 60
        let focus: Double? = good ? 70 : nil
        let rms: Double = good ? 12 : 0.3
        let state: BrainState = good ? .focused : .withheld
        eps.append(Epoch(t: Double(i), focus: focus, calm: nil, clench: nil, engagement: 1,
                         bands: [:], alphaPeak: nil, rmsUv: rms,
                         signalOk: good, fsOk: true, calibrating: false, state: state))
    }
    let s = SessionRecord(startedAt: start, endedAt: start.addingTimeInterval(120),
                          device: DeviceInfo(name: "t", sps: 175), baseline: nil,
                          epochs: eps, activities: [], markers: [])
    let day = rollUp(sessions: [s], markers: [], date: start)

    // A trustworthy second.
    let good = epochAt(day, start.addingTimeInterval(10))
    #expect(good?.trustworthy == true)
    #expect(good?.focus == 70)

    // A withheld second: found, but with no number to show.
    let dead = epochAt(day, start.addingTimeInterval(90))
    #expect(dead?.state == .withheld)
    #expect(dead?.focus == nil)

    // Between sessions: nothing.
    #expect(epochAt(day, start.addingTimeInterval(9999)) == nil)
}
