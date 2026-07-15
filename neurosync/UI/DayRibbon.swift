//
//  DayRibbon.swift
//  neurosync
//
//  The day, on four lanes:
//
//    ACTIVITY   what you were doing        (calendar · observed · self-reported)
//    STATE      what your brain was doing  (focused · daydream · calm · clenched · withheld)
//    FOCUS      the 0–100 line             (baseline 50, flow line 60)
//    MARKERS    what you said              (stressed · break · walk · coffee)
//
//  The rule that governs every pixel here: A GAP IS DRAWN AS A GAP.
//
//  Withheld seconds are not shaded to the last good value, not interpolated across, and not joined
//  by the focus line. Where the instrument had nothing to say, the ribbon has nothing to draw. A
//  timeline that bridges its own dropouts is a timeline that lies about how much of the day it
//  actually saw — and the moment it does that, coverage becomes unfalsifiable.
//

import SwiftUI

// MARK: - Axis

nonisolated struct TimeAxis {
    let start: Date
    let end: Date
    let width: CGFloat

    var span: TimeInterval { max(1, end.timeIntervalSince(start)) }

    func x(_ t: Date) -> CGFloat {
        CGFloat(t.timeIntervalSince(start) / span) * width
    }

    func w(from: Date, to: Date) -> CGFloat {
        max(1, x(to) - x(from))
    }
}

/// The window the day is drawn in: the data's own extent, snapped out to whole hours.
/// Not a fixed 00:00–24:00 — twelve empty hours either side of the data would compress the part
/// that matters into nothing.
nonisolated func dayWindow(_ day: Day, calendar cal: Calendar = .current) -> (Date, Date) {
    let starts = day.sessions.map(\.startedAt) + day.markers.map(\.at)
    let ends = day.sessions.map(\.endedAt) + day.markers.map(\.at)

    guard let lo = starts.min(), let hi = ends.max() else {
        let base = cal.startOfDay(for: day.date)
        return (cal.date(byAdding: .hour, value: 8, to: base) ?? base,
                cal.date(byAdding: .hour, value: 18, to: base) ?? base)
    }

    let floorHr = cal.dateInterval(of: .hour, for: lo)?.start ?? lo
    let ceilHr = cal.dateInterval(of: .hour, for: hi)?.end ?? hi
    return (floorHr, ceilHr)
}

// MARK: - Runs

nonisolated struct StateRun: Identifiable {
    let id = UUID()
    let state: BrainState
    let start: Date
    let end: Date
}

/// Collapse per-second epochs into contiguous same-state runs, per session.
///
/// Runs never span two sessions: the board was off in between, and drawing across that would invent
/// a state for time that was not recorded.
nonisolated func stateRuns(_ day: Day) -> [StateRun] {
    var out: [StateRun] = []
    for s in day.sessions {
        guard var runState = s.epochs.first?.state else { continue }
        var runStart = s.date(at: 0)

        for e in s.epochs.dropFirst() {
            if e.state != runState {
                out.append(StateRun(state: runState, start: runStart, end: s.date(at: e.t)))
                runState = e.state
                runStart = s.date(at: e.t)
            }
        }
        out.append(StateRun(state: runState, start: runStart, end: s.endedAt))
    }
    return out
}

/// The focus polyline, BROKEN at every withheld second.
///
/// Returns one array per unbroken stretch. A single flattened array would let SwiftUI draw a
/// straight line across a fifteen-minute dropout, which is exactly the lie this app is built to
/// refuse — and it would look like a perfectly steady score.
nonisolated func focusPolylines(_ day: Day, everyNth: Int = 5) -> [[(Date, Double)]] {
    var out: [[(Date, Double)]] = []
    for s in day.sessions {
        var run: [(Date, Double)] = []
        for (i, e) in s.epochs.enumerated() {
            guard let f = e.focus, e.trustworthy else {
                if run.count > 1 { out.append(run) }
                run = []
                continue
            }
            if i % everyNth == 0 { run.append((s.date(at: e.t), f)) }
        }
        if run.count > 1 { out.append(run) }
    }
    return out
}

// MARK: - Ribbon

struct DayRibbon: View {
    let day: Day
    var height: CGFloat = 216

    private let laneH: CGFloat = 26
    private let gap: CGFloat = 10

    var body: some View {
        let (t0, t1) = dayWindow(day)

        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let ax = TimeAxis(start: t0, end: t1, width: geo.size.width)
                let runs = stateRuns(day)
                let lines = focusPolylines(day)

                ZStack(alignment: .topLeading) {
                    HourGrid(axis: ax, height: geo.size.height)

                    VStack(alignment: .leading, spacing: gap) {
                        LaneLabel("ACTIVITY")
                        ActivityLane(day: day, axis: ax).frame(height: laneH)

                        LaneLabel("BRAIN STATE")
                        StateLane(runs: runs, axis: ax).frame(height: laneH)

                        LaneLabel("FOCUS")
                        FocusLane(lines: lines, axis: ax).frame(height: 54)

                        MarkerLane(day: day, axis: ax).frame(height: 18)
                    }
                }
            }
            .frame(height: height)

            HourAxisLabels(start: t0, end: t1)
        }
    }
}

private struct LaneLabel: View {
    let text: String
    init(_ t: String) { text = t }

    var body: some View {
        Text(text)
            .font(.data(8, .semibold))
            .tracking(1.2)
            .foregroundStyle(Ink.muted)
    }
}

// MARK: Grid

private struct HourGrid: View {
    let axis: TimeAxis
    let height: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            let cal = Calendar.current
            var t = cal.dateInterval(of: .hour, for: axis.start)?.start ?? axis.start
            while t <= axis.end {
                var p = Path()
                p.move(to: CGPoint(x: axis.x(t), y: 0))
                p.addLine(to: CGPoint(x: axis.x(t), y: height))
                ctx.stroke(p, with: .color(Ink.rule), lineWidth: 1)
                t = t.addingTimeInterval(3600)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct HourAxisLabels: View {
    let start: Date
    let end: Date

    var body: some View {
        GeometryReader { geo in
            let ax = TimeAxis(start: start, end: end, width: geo.size.width)
            let cal = Calendar.current
            let hours = stride(
                from: 0,
                to: Int(end.timeIntervalSince(start) / 3600) + 1,
                by: max(1, Int(end.timeIntervalSince(start) / 3600) / 12 + 1)
            ).compactMap { cal.date(byAdding: .hour, value: $0, to: start) }

            ForEach(hours, id: \.self) { h in
                Text(clock(h))
                    .font(.data(8))
                    .foregroundStyle(Ink.muted)
                    .fixedSize()
                    .position(x: ax.x(h) + 12, y: 6)
            }
        }
        .frame(height: 12)
    }
}

// MARK: Lanes

private struct ActivityLane: View {
    let day: Day
    let axis: TimeAxis

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Ink.panel)

            ForEach(day.sessions.flatMap(\.activities)) { span in
                let w = axis.w(from: span.start, to: span.end)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Ink.activity(span.kind))
                    if w > 64 {
                        Text(span.label)
                            .font(.data(9, .semibold))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                            .padding(.leading, 6)
                    }
                }
                .frame(width: w)
                .overlay(Rectangle().strokeBorder(Ink.bg.opacity(0.6), lineWidth: 1))
                .offset(x: axis.x(span.start))
                .help("\(span.kind.label) · \(span.label) · \(clock(span.start))–\(clock(span.end)) · \(span.source.label)")
            }
        }
    }
}

private struct StateLane: View {
    let runs: [StateRun]
    let axis: TimeAxis

    var body: some View {
        ZStack(alignment: .leading) {
            // The void. Anything not covered by a run is time the board was not on your head, and
            // it stays this colour.
            Rectangle().fill(Ink.panel)

            ForEach(runs) { r in
                Rectangle()
                    .fill(Ink.state(r.state))
                    .frame(width: axis.w(from: r.start, to: r.end))
                    .offset(x: axis.x(r.start))
                    .help("\(r.state.label) · \(clock(r.start))–\(clock(r.end))\n\n\(r.state.meaning)")
            }
        }
    }
}

private struct FocusLane: View {
    let lines: [[(Date, Double)]]
    let axis: TimeAxis

    var body: some View {
        Canvas { ctx, size in
            func y(_ v: Double) -> CGFloat {
                size.height - CGFloat(v / 100) * size.height
            }

            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Ink.panel))

            // Your own baseline, and the flow line. 50 is not "average" — it is YOU.
            for (v, c) in [(50.0, Ink.rule), (flowThreshold, Ink.amber.opacity(0.22))] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y(v)))
                p.addLine(to: CGPoint(x: size.width, y: y(v)))
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            for line in lines {
                guard line.count > 1 else { continue }
                var p = Path()
                p.move(to: CGPoint(x: axis.x(line[0].0), y: y(line[0].1)))
                for pt in line.dropFirst() {
                    p.addLine(to: CGPoint(x: axis.x(pt.0), y: y(pt.1)))
                }
                ctx.stroke(p, with: .color(Ink.amber), lineWidth: 1.2)
            }
        }
    }
}

private struct MarkerLane: View {
    let day: Day
    let axis: TimeAxis

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(day.markers) { m in
                Image(systemName: m.kind.glyph)
                    .font(.system(size: 9))
                    .foregroundStyle(Ink.dim)
                    .frame(width: 16, height: 16)
                    .background(Ink.panel)
                    .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
                    .offset(x: axis.x(m.at) - 8)
                    .help("\(m.kind.label) · \(clock(m.at)) · self-reported\(m.note.map { "\n\"\($0)\"" } ?? "")")
            }
        }
    }
}
