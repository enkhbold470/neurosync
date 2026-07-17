//
//  TimelineViewport.swift
//  neurosync
//
//  The zoom/pan math for the DAY timeline, kept pure and nonisolated so it can be tested without a
//  view. A viewport is a visible sub-window [start, start+span] of a fixed day [dayStart, dayEnd].
//  Every zoom and pan runs through `clamp()`, so the viewport can never escape the day's bounds and
//  can never zoom past the 60 s floor (the data is 1 Hz — a narrower window would just magnify
//  nothing) nor past the whole-day ceiling.
//

import Foundation

nonisolated struct Viewport: Equatable {
    let dayStart: Date
    let dayEnd: Date
    private(set) var start: Date
    private(set) var span: TimeInterval

    /// The narrowest window we allow. Below this you would be zooming into the space between two
    /// 1 Hz samples, which shows nothing new.
    static let minSpan: TimeInterval = 60

    init(dayStart: Date, dayEnd: Date, start: Date? = nil, span: TimeInterval? = nil) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.start = start ?? dayStart
        self.span = span ?? Self.rawDaySpan(dayStart, dayEnd)
        clampInPlace()
    }

    private static func rawDaySpan(_ a: Date, _ b: Date) -> TimeInterval {
        max(minSpan, b.timeIntervalSince(a))
    }

    /// The full day, in seconds. Never below `minSpan`.
    var daySpan: TimeInterval { Self.rawDaySpan(dayStart, dayEnd) }
    var end: Date { start.addingTimeInterval(span) }

    /// How much of the day this window covers, 0..1 — the minimap window width.
    var coverage: Double { min(1, span / daySpan) }

    /// Where the window sits, 0..1 — the minimap window offset.
    var offsetFraction: Double {
        let range = daySpan - span
        guard range > 0 else { return 0 }
        return min(1, max(0, start.timeIntervalSince(dayStart) / range))
    }

    // MARK: Mutations — all end in a clamp.

    private mutating func clampInPlace() {
        span = min(max(span, Self.minSpan), daySpan)
        let maxOffset = max(0, daySpan - span)
        let off = min(max(start.timeIntervalSince(dayStart), 0), maxOffset)
        start = dayStart.addingTimeInterval(off)
    }

    func clamped() -> Viewport { var v = self; v.clampInPlace(); return v }

    /// Zoom by `factor` (> 1 zooms IN → smaller span), keeping the time under unit position
    /// `anchor` (0 = left edge, 1 = right edge) pinned on screen. Anchoring is what makes a
    /// pinch feel like it happens under your fingers rather than around the middle.
    func zoomed(factor: Double, anchor: Double) -> Viewport {
        guard factor > 0, factor.isFinite else { return self }
        let a = min(max(anchor, 0), 1)
        let anchoredTime = start.addingTimeInterval(span * a)
        var newSpan = span / factor
        newSpan = min(max(newSpan, Self.minSpan), daySpan)
        var v = self
        v.span = newSpan
        v.start = anchoredTime.addingTimeInterval(-newSpan * a)
        v.clampInPlace()
        return v
    }

    func panned(bySeconds ds: TimeInterval) -> Viewport {
        var v = self
        v.start = start.addingTimeInterval(ds)
        v.clampInPlace()
        return v
    }

    /// Move the window so its CENTRE sits at `t` (used by the minimap drag).
    func centered(on t: Date) -> Viewport {
        var v = self
        v.start = t.addingTimeInterval(-span / 2)
        v.clampInPlace()
        return v
    }

    func fitted() -> Viewport {
        var v = self
        v.start = dayStart
        v.span = daySpan
        v.clampInPlace()
        return v
    }

    /// Zoom to an explicit range — the ruler marquee.
    func ranged(_ a: Date, _ b: Date) -> Viewport {
        let lo = min(a, b), hi = max(a, b)
        var v = self
        v.span = min(max(hi.timeIntervalSince(lo), Self.minSpan), daySpan)
        v.start = lo
        v.clampInPlace()
        return v
    }
}

// MARK: - Ruler ticks

/// The ladder of "nice" tick steps, in seconds. Adjacent-to-major ratios are all integers, so a
/// tick's major-ness is a clean modulo (see `rulerTicks`).
nonisolated let tickLadder: [TimeInterval] = [
    10, 15, 30, 60, 120, 300, 600, 900, 1800,
    3600, 2 * 3600, 3 * 3600, 6 * 3600, 12 * 3600
]

nonisolated struct RulerTick: Equatable {
    let date: Date
    /// Major ticks get a label; minor ticks are just a hairline.
    let major: Bool
}

/// Ticks for the visible window, spaced ≥ `minPixels` apart, aligned to absolute clock boundaries
/// relative to `epoch` (pass the day's midnight so labels land on :00 / :15 / …).
nonisolated func rulerTicks(start: Date, span: TimeInterval, width: CGFloat,
                            epoch: Date, minPixels: CGFloat = 76) -> [RulerTick] {
    guard width > 0, span > 0 else { return [] }
    let secPerPx = span / Double(width)
    let step = tickLadder.first { $0 >= secPerPx * Double(minPixels) } ?? tickLadder.last!
    let majorStep = tickLadder.first { $0 >= step * 4 } ?? step
    let ratio = max(1, Int((majorStep / step).rounded()))

    let e = epoch.timeIntervalSinceReferenceDate
    let s = start.timeIntervalSinceReferenceDate
    let endT = s + span

    var k = Int(ceil((s - e) / step - 1e-6))
    var out: [RulerTick] = []
    while true {
        let t = e + Double(k) * step
        if t > endT + 1e-6 { break }
        let major = (((k % ratio) + ratio) % ratio) == 0
        out.append(RulerTick(date: Date(timeIntervalSinceReferenceDate: t), major: major))
        k += 1
        if out.count > 4000 { break }   // safety net; never hit at legal zoom
    }
    return out
}

/// Human span label: "2h 15m", "8m 30s", "45s".
nonisolated func spanLabel(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    if m > 0 { return sec > 0 ? "\(m)m \(sec)s" : "\(m)m" }
    return "\(sec)s"
}
