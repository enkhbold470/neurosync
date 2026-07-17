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

    /// The inverse of `x` — what time sits under a pixel. Used by the scrubber and the minimap drag.
    func time(atX px: CGFloat) -> Date {
        start.addingTimeInterval(Double(px / max(1, width)) * span)
    }
}

/// The epoch under a wall-clock instant, or nil if no session was recording then. Epochs are 1 Hz
/// with `t` in whole seconds from the session start, so this is a floor + index.
nonisolated func epochAt(_ day: Day, _ t: Date) -> Epoch? {
    for s in day.sessions where t >= s.startedAt && t < s.endedAt {
        let idx = Int(t.timeIntervalSince(s.startedAt))
        if s.epochs.indices.contains(idx) { return s.epochs[idx] }
    }
    return nil
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

// MARK: - Ribbon (zoomable, video-editor style)

/// A zoomable/pannable timeline over one day. The lanes, ruler and grid all draw through a
/// `TimeAxis` built over the VISIBLE window (`viewport`), not the whole day — so pinching, panning,
/// the minimap and the marquee just move that window and everything reprojects. The "a gap is a gap"
/// rule survives every zoom: a dropout only gets wider, never bridged, and the scrubber refuses to
/// read a value out of a withheld second.
struct DayRibbon: View {
    let day: Day
    var height: CGFloat = 200

    @State private var viewport: Viewport
    @State private var hoverX: CGFloat?
    @State private var panBase: Viewport?
    @State private var pinchBase: Viewport?
    @FocusState private var focused: Bool

    private let laneH: CGFloat = 32
    private let gap: CGFloat = 12

    init(day: Day, height: CGFloat = 230) {
        self.day = day
        self.height = height
        let (t0, t1) = dayWindow(day)
        _viewport = State(initialValue: Viewport(dayStart: t0, dayEnd: t1))
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let ax = TimeAxis(start: viewport.start, end: viewport.end, width: w)

            VStack(alignment: .leading, spacing: 8) {
                controls
                Minimap(day: day, viewport: viewport) { viewport = $0 }
                    .frame(height: 26)
                Ruler(viewport: viewport) { a, b in viewport = viewport.ranged(a, b) }
                    .frame(height: 24)
                lanes(ax: ax, width: w)
                    .padding(.top, 2)
            }
        }
        .frame(height: height + 106)   // lanes(height) + controls(28)+minimap(26)+ruler(22) + 3×8 + slack
        .focusable()
        .focused($focused)
        .onKeyPress(action: handleKey)
        .onChange(of: day.key) { _, _ in
            let (t0, t1) = dayWindow(day)
            viewport = Viewport(dayStart: t0, dayEnd: t1)
            hoverX = nil
        }
    }

    // MARK: Lanes

    private func lanes(ax: TimeAxis, width w: CGFloat) -> some View {
        // One point per pixel at most — full detail when zoomed in, subsampled at the day scale.
        let everyNth = max(1, Int((viewport.span / Double(w)).rounded()))
        let runs = stateRuns(day)
        let lines = focusPolylines(day, everyNth: everyNth)

        return ZStack(alignment: .topLeading) {
            TickGrid(viewport: viewport)

            VStack(alignment: .leading, spacing: gap) {
                LaneLabel("ACTIVITY")
                ActivityLane(day: day, axis: ax).frame(height: laneH).clipped()

                LaneLabel("BRAIN STATE")
                StateLane(runs: runs, axis: ax).frame(height: laneH).clipped()

                LaneLabel("FOCUS")
                FocusLane(lines: lines, axis: ax).frame(height: 58)

                MarkerLane(day: day, axis: ax).frame(height: 24).clipped()
            }

            Scrubber(day: day, axis: ax, hoverX: hoverX, width: w)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoverX = p.x
            case .ended: hoverX = nil
            }
        }
        .gesture(panGesture(width: w))
        .simultaneousGesture(pinchGesture(width: w))
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            zoomButton("minus") { viewport = viewport.zoomed(factor: 1 / 1.6, anchor: 0.5) }
            Text(spanLabel(viewport.span))
                .font(.data(13, .semibold))
                .foregroundStyle(Ink.text)
                .frame(minWidth: 72)
                .multilineTextAlignment(.center)
            zoomButton("plus") { viewport = viewport.zoomed(factor: 1.6, anchor: 0.5) }

            Button("FIT") { viewport = viewport.fitted() }
                .font(.data(12, .semibold))
                .foregroundStyle(Ink.dim)
                .buttonStyle(.plain)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))

            Spacer()

            Text("pinch to zoom · drag to pan · drag ruler to select · F to fit")
                .font(.data(12))
                .foregroundStyle(Ink.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(height: 28)
    }

    private func zoomButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Ink.dim)
                .frame(width: 28, height: 26)
                .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Gestures

    private func panGesture(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { g in
                let base = panBase ?? viewport
                if panBase == nil { panBase = viewport }
                let secPerPx = base.span / Double(w)
                viewport = base.panned(bySeconds: -Double(g.translation.width) * secPerPx)
            }
            .onEnded { _ in panBase = nil }
    }

    private func pinchGesture(width w: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let base = pinchBase ?? viewport
                if pinchBase == nil { pinchBase = viewport }
                viewport = base.zoomed(factor: Double(v.magnification), anchor: v.startAnchor.x)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:  viewport = viewport.panned(bySeconds: -viewport.span * 0.2); return .handled
        case .rightArrow: viewport = viewport.panned(bySeconds:  viewport.span * 0.2); return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "+", "=": viewport = viewport.zoomed(factor: 1.6, anchor: 0.5); return .handled
        case "-", "_": viewport = viewport.zoomed(factor: 1 / 1.6, anchor: 0.5); return .handled
        case "f":      viewport = viewport.fitted(); return .handled
        default: return .ignored
        }
    }
}

private struct LaneLabel: View {
    let text: String
    init(_ t: String) { text = t }

    var body: some View {
        Text(text)
            .font(.data(12, .semibold))
            .tracking(1.4)
            .foregroundStyle(Ink.muted)
    }
}

// MARK: Ruler

/// The adaptive time ruler. Ticks thin out as you zoom, labels land on clock boundaries, and a
/// drag on it marquee-selects a range to zoom into.
private struct Ruler: View {
    let viewport: Viewport
    let onRange: (Date, Date) -> Void

    @State private var sel: (CGFloat, CGFloat)?

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let ax = TimeAxis(start: viewport.start, end: viewport.end, width: w)
            let epoch = Calendar.current.startOfDay(for: viewport.dayStart)
            // Wider min spacing than the grid so 12pt labels never collide.
            let ticks = rulerTicks(start: viewport.start, span: viewport.span, width: w,
                                   epoch: epoch, minPixels: 120)
            let showSec = viewport.span < 1200

            ZStack(alignment: .topLeading) {
                Rectangle().fill(Ink.panel)

                Canvas { ctx, size in
                    for t in ticks {
                        let x = ax.x(t.date)
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: t.major ? 0 : size.height * 0.5))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(p, with: .color(t.major ? Ink.rule : Ink.rule.opacity(0.5)),
                                   lineWidth: 1)
                    }
                }

                ForEach(ticks.filter(\.major), id: \.date) { t in
                    Text(showSec ? clockSec(t.date) : clock(t.date))
                        .font(.data(12))
                        .foregroundStyle(Ink.dim)
                        .fixedSize()
                        // Sit just right of the tick, but never off either edge.
                        .position(x: min(max(ax.x(t.date) + 26, 24), w - 28), y: 11)
                }

                if let sel {
                    let a = min(sel.0, sel.1), b = max(sel.0, sel.1)
                    Rectangle()
                        .fill(Ink.amber.opacity(0.18))
                        .frame(width: max(1, b - a))
                        .offset(x: a)
                }
            }
            .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in sel = (g.startLocation.x, g.location.x) }
                    .onEnded { g in
                        sel = nil
                        if abs(g.location.x - g.startLocation.x) > 6 {
                            onRange(ax.time(atX: g.startLocation.x), ax.time(atX: g.location.x))
                        }
                    }
            )
        }
    }
}

// MARK: Minimap

/// A full-day overview strip. The whole timeline at a glance, with the current viewport drawn as a
/// window you can drag to scrub.
private struct Minimap: View {
    let day: Day
    let viewport: Viewport
    let onScrub: (Viewport) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let mm = TimeAxis(start: viewport.dayStart, end: viewport.dayEnd, width: w)
            let runs = stateRuns(day)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Ink.panel))
                    for r in runs {
                        let x = mm.x(r.start)
                        let rw = mm.w(from: r.start, to: r.end)
                        ctx.fill(Path(CGRect(x: x, y: 0, width: rw, height: size.height)),
                                 with: .color(Ink.state(r.state)))
                    }
                }

                // The viewport window.
                Rectangle()
                    .fill(Ink.amber.opacity(0.14))
                    .frame(width: max(3, mm.w(from: viewport.start, to: viewport.end)))
                    .overlay(Rectangle().strokeBorder(Ink.amber, lineWidth: 1))
                    .offset(x: mm.x(viewport.start))
            }
            .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in onScrub(viewport.centered(on: mm.time(atX: g.location.x))) }
            )
        }
    }
}

// MARK: Grid

/// Vertical hairlines at the ruler's major ticks — the same alignment as the labels above.
private struct TickGrid: View {
    let viewport: Viewport

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let ax = TimeAxis(start: viewport.start, end: viewport.end, width: w)
            let epoch = Calendar.current.startOfDay(for: viewport.dayStart)
            // Same spacing as the ruler labels so the major gridlines sit under the labels.
            let ticks = rulerTicks(start: viewport.start, span: viewport.span, width: w,
                                   epoch: epoch, minPixels: 120)
            Canvas { ctx, size in
                for t in ticks where t.major {
                    var p = Path()
                    p.move(to: CGPoint(x: ax.x(t.date), y: 0))
                    p.addLine(to: CGPoint(x: ax.x(t.date), y: size.height))
                    ctx.stroke(p, with: .color(Ink.rule), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Scrubber

/// The playhead. Follows the cursor, reads the epoch under it, and — critically — refuses to invent
/// a value over a withheld second: a gap reads WITHHELD, never an interpolated number.
private struct Scrubber: View {
    let day: Day
    let axis: TimeAxis
    let hoverX: CGFloat?
    let width: CGFloat

    var body: some View {
        GeometryReader { geo in
            if let x = hoverX, x >= 0, x <= width {
                let t = axis.time(atX: x)
                let e = epochAt(day, t)

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Ink.text.opacity(0.55))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .offset(x: x)

                    readout(t: t, e: e)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Ink.bg.opacity(0.94))
                        .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
                        .offset(x: min(max(0, x + 10), max(0, geo.size.width - 300)), y: 2)
                }
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func readout(t: Date, e: Epoch?) -> some View {
        HStack(spacing: 10) {
            Text(clockSec(t)).font(.data(13, .semibold)).foregroundStyle(Ink.text)

            if let e {
                if e.trustworthy, let f = e.focus {
                    Text("FOCUS \(Int(f.rounded()))")
                        .foregroundStyle(f >= flowThreshold ? Ink.amber : Ink.dim)
                    Text(e.state.label).foregroundStyle(Ink.state(e.state))
                    Text("CLENCH \(Int((e.clench ?? 0).rounded()))").foregroundStyle(Ink.muted)
                } else {
                    Text(e.state.label).foregroundStyle(Ink.warn)
                }
            } else {
                Text("NO DATA").foregroundStyle(Ink.muted)
            }
        }
        .font(.data(12))
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
                    if w > 80 {
                        Text(span.label)
                            .font(.data(12, .semibold))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                            .padding(.leading, 8)
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
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.dim)
                    .frame(width: 22, height: 22)
                    .background(Ink.panel)
                    .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
                    .offset(x: axis.x(m.at) - 11)
                    .help("\(m.kind.label) · \(clock(m.at)) · self-reported\(m.note.map { "\n\"\($0)\"" } ?? "")")
            }
        }
    }
}
