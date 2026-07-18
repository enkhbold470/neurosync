//
//  Snapshots.swift
//  neurosyncTests
//
//  Renders the real SwiftUI views to PNG — no board and no screen-recording permission needed.
//  These are the images in the README.
//
//  IMPORTANT: the waveform driving these is a SYNTHETIC TEST FIXTURE, not a brain. It is fed
//  through the real DSP, so the spectrum, the band powers and the score are all genuinely
//  computed — but the input is a signal generator, and the README says so. The app itself has no
//  signal generator and never will (Manifesto II). The fixture is an input, never an output.
//

import Testing
import SwiftUI
import Foundation
@testable import neurosync

@MainActor
private func render(_ view: some View, size: CGSize, to name: String) throws -> String {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 2

    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("neurosync-shots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)

    guard let cg = renderer.cgImage else { throw SnapshotError.renderFailed }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw SnapshotError.encodeFailed
    }
    try png.write(to: url)
    return url.path
}

private enum SnapshotError: Error { case renderFailed, encodeFailed }

/// Deterministic noise. Real EEG is not a sum of clean sines; without a broadband floor the
/// scope looks like a function generator. Seeded, so the snapshots are reproducible.
private struct LCG {
    var s: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}

/// A full, physiologically-shaped session — the way the instrument is actually used:
///
///   1. 24 s at rest. The engine collects 160 gated updates and freezes YOUR baseline as the
///      median. By construction a freshly-calibrated user therefore sits at ~50.
///   2. 8 s concentrating: alpha falls, beta rises, so β/(α+θ) climbs above baseline and the
///      score rises past the flow line.
///
/// Pinning `baselineEngagement` to an arbitrary constant instead would produce a score that no
/// real calibrated user could ever show. This runs the real calibration, on a fixture.
@MainActor
private func fixture() -> (FocusMetrics, [Double]) {
    let fs = 175.0
    let e = FocusEngine(fs: fs)
    var rng = LCG()
    var pink = 0.0

    func drive(seconds: Double, from: Double, theta: Double, alpha: Double, beta: Double) {
        for i in 0..<Int(seconds * fs) {
            let t = from + Double(i) / fs
            pink = pink * 0.92 + rng.next() * 2.6            // low-frequency wander
            let uv = pink
                + theta * sin(2 * .pi * 6.2 * t)
                + alpha * sin(2 * .pi * 10.1 * t + 0.7)
                + beta  * sin(2 * .pi * 19.0 * t + 1.9)
                + 1.4 * rng.next()                           // broadband floor
            e.push(counts: Int32((uv / countsToUv(1.0)).rounded()))
        }
    }

    drive(seconds: 24, from: 0, theta: 8.0, alpha: 10.0, beta: 8.0)     // rest → baseline
    drive(seconds: 8, from: 24, theta: 7.5, alpha: 9.0, beta: 8.8)      // concentrating
    return (e.metrics, e.window)
}

// MARK: - README images

@MainActor
@Test func snapshotNoDevice() throws {
    // 100% real: this is exactly what the app shows with no board. No fixture involved.
    let path = try render(ContentView(model: VertexModel(), days: DayModel()),
                          size: CGSize(width: 1180, height: 760), to: "01-no-device.png")
    print("SNAPSHOT \(path)")
    #expect(FileManager.default.fileExists(atPath: path))
}

/// The connect hero in both appearances — proves the adaptive tokens flip and stay legible.
@MainActor
@Test func snapshotConnectAppearances() throws {
    for scheme in [ColorScheme.light, .dark] {
        let name = scheme == .light ? "01a-connect-light.png" : "01b-connect-dark.png"
        let v = ContentView(model: VertexModel(), days: DayModel())
            .environment(\.colorScheme, scheme)
        let path = try render(v, size: CGSize(width: 1180, height: 760), to: name)
        print("SNAPSHOT \(path)")
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

@MainActor
@Test func snapshotInstrument() throws {
    let (m, wave) = fixture()

    var snap = VertexSnapshot()
    snap.metrics = m
    snap.waveform = wave
    snap.fs = 175
    snap.info = Vertex.Info(fw: "v4.1", sps: 175, mode: "binary_batch", batch: 6,
                            bits: 24, vref: 3.3, pga: 1, afe: 1.0, name: Vertex.deviceName)

    let view = HStack(alignment: .top, spacing: 14) {
        VStack(spacing: 14) {
            Panel(title: "SCOPE", trailing: "175 SPS · 1–45 Hz band-pass") {
                ScopeView(samples: wave, live: true).frame(height: 168)
            }
            Panel(title: "SPECTRUM", trailing: "Welch · Hann · 75% overlap") {
                SpectrumView(psd: m.psd, alphaPeak: m.alphaPeak, live: true).frame(height: 150)
            }
            Spacer(minLength: 0)
        }
        VStack(spacing: 14) {
            FocusPanel(metrics: m, withheld: false, onRecalibrate: {})
            BergerPanel(metrics: m, alphaHistory: [], live: true)
            SignalPanel(snap: snap, onDiag: {})
            Spacer(minLength: 0)
        }
        .frame(width: 340)
    }
    .padding(14)
    .background(Ink.bg)

    let path = try render(view, size: CGSize(width: 1180, height: 800), to: "02-instrument.png")
    print("SNAPSHOT \(path)")
    #expect(m.alphaPeak != nil)
    #expect(m.signalOk)
}

@MainActor
@Test func snapshotGates() throws {
    // The three refusals. Every word of gate text here is produced by the real gate logic.
    var rateM = FocusMetrics()
    rateM.fsOk = false
    rateM.fsReason = focusFeasibility(fs: 90).reason

    var sigM = FocusMetrics()
    sigM.warmingUp = false
    sigM.signalOk = false
    sigM.rmsUv = 0.31

    var calM = FocusMetrics()
    calM.warmingUp = false
    calM.signalOk = true
    calM.calibrating = true
    calM.calibrationLeftSec = 12

    let gates = [rateM, sigM, calM].compactMap { blockingGate(connected: true, metrics: $0) }

    let view = VStack(spacing: 12) {
        ForEach(Array(gates.enumerated()), id: \.offset) { _, g in
            GateBanner(gate: g, onFixRate: g.kind == .rate ? {} : nil)
        }
    }
    .padding(18)
    .background(Ink.bg)

    let path = try render(view, size: CGSize(width: 900, height: 300), to: "03-gates.png")
    print("SNAPSHOT \(path)")
    #expect(gates.count == 3)
    #expect(gates[0].kind == .rate)
}

@MainActor
@Test func snapshotMenuBar() throws {
    let path = try render(MenuBarPanel(model: VertexModel()).background(Ink.bg),
                          size: CGSize(width: 280, height: 190), to: "04-menubar.png")
    print("SNAPSHOT \(path)")
    #expect(FileManager.default.fileExists(atPath: path))
}

/// The DAY view, populated. Proves the timeline Canvas, the state runs, the withheld gaps, and the
/// findings layout all compose and render — the visual counterpart to the data-level tests in
/// DayTests. The signal behind it is a fixture through the real DSP.
@MainActor
@Test func snapshotDayTimeline() throws {
    let day = snapshotFixtureDay()

    // No ScrollView: ImageRenderer renders a ScrollView's scroll axis as empty. A fixed VStack lets
    // DayRibbon's internal GeometryReader read a real width.
    let view = VStack(alignment: .leading, spacing: 14) {
        Panel(title: "TIMELINE", trailing: String(format: "%.0f%% coverage · 1 session", day.coverage * 100)) {
            DayRibbon(day: day)
        }
        Panel(title: "FINDINGS", trailing: "\(day.findings.count)") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(day.findings) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.headline).font(.label(12, .semibold)).foregroundStyle(Ink.text)
                        Text(f.caveat).font(.label(11)).foregroundStyle(Ink.muted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Spacer(minLength: 0)
    }
    .padding(14)
    .frame(width: 1120, height: 820, alignment: .top)
    .background(Ink.bg)

    let path = try render(view, size: CGSize(width: 1120, height: 820), to: "05-day-timeline.png")
    print("SNAPSHOT \(path)")
    #expect(day.synthetic)
    #expect(!day.findings.isEmpty)
}

/// The new visual layer — icon chips, metric meters, ring gauges — over fixture data, so the
/// glanceable DAY view can be reviewed without hardware.
@MainActor
@Test func snapshotDayVisuals() throws {
    let day = snapshotFixtureDay()
    let seg = day.segments.first!

    func metric(_ label: String, _ display: String, _ v: Double, _ tint: Color, baseline: Double? = nil) -> MetricCell {
        MetricCell(label: label, display: display, value: v, tint: tint, baseline: baseline)
    }

    let blockRow = HStack(alignment: .center, spacing: 14) {
        IconChip(system: seg.span.kind.icon, tint: Ink.activity(seg.span.kind), size: 34)
        VStack(alignment: .leading, spacing: 2) {
            Text(seg.span.label).font(.label(14, .semibold)).foregroundStyle(Ink.text)
            Text("\(seg.span.kind.label) · \(clock(seg.span.start))–\(clock(seg.span.end))")
                .font(.data(11)).foregroundStyle(Ink.muted)
        }
        .frame(width: 244, alignment: .leading)
        Spacer(minLength: 0)
        metric("FOCUS", String(format: "%.0f", seg.medianFocus ?? 0), (seg.medianFocus ?? 0) / 100, Ink.amber, baseline: 0.5)
        metric("FLOW", "\(Int(seg.share(.focused) * 100))%", seg.share(.focused), Ink.amber)
        metric("DAYDREAM", "\(Int(seg.share(.daydream) * 100))%", seg.share(.daydream), Ink.state(.daydream))
        metric("COVERAGE", "\(Int(seg.coverage * 100))%", seg.coverage, Ink.dim)
    }
    .padding(.vertical, 10)

    let gauges = HStack(spacing: 24) {
        RingGauge(value: (day.cognitiveStrainProxy ?? 40) / 100,
                  center: String(format: "%.0f", day.cognitiveStrainProxy ?? 40), unit: "/100", tint: Ink.amber)
        RingGauge(value: 0.35, center: "35", unit: "%", tint: Ink.state(.calm))
        HStack(spacing: 12) {
            ForEach([FindingTone.bad, .good, .caution, .neutral], id: \.self) { t in
                HStack(spacing: 6) {
                    Image(systemName: t.icon).foregroundStyle(Ink.tone(t))
                    Text(t.rawValue.uppercased()).font(.data(11)).foregroundStyle(Ink.dim)
                }
            }
        }
    }

    let view = VStack(alignment: .leading, spacing: 18) {
        Panel(title: "BLOCKS", trailing: "median focus · baseline is 50") { blockRow }
        gauges.padding(.horizontal, 4)
    }
    .padding(16)
    .frame(width: 1120, height: 380, alignment: .top)
    .background(Ink.bg)

    let path = try render(view, size: CGSize(width: 1120, height: 380), to: "06-day-visuals.png")
    print("SNAPSHOT \(path)")
    #expect(FileManager.default.fileExists(atPath: path))
}

/// A short real session through the real DSP, rolled up — enough to populate the timeline snapshot
/// without generating the full two days.
@MainActor
private func snapshotFixtureDay() -> Day {
    let fs = 175.0
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let blocks = [
        SynthBlock(startSec: 0, durationSec: 40, profile: .baseline, rampSec: 0),
        SynthBlock(startSec: 40, durationSec: 150, profile: .focused, rampSec: 15),
        SynthBlock(startSec: 190, durationSec: 60, profile: .off, rampSec: 0),
        SynthBlock(startSec: 250, durationSec: 190, profile: .disengaged, rampSec: 20)
    ]
    let counts = synthesizeCounts(blocks: blocks, fs: fs, durationSec: 440, seed: 0xD00D)
    let span = ActivitySpan(kind: .coding, label: "Claude coding", start: start,
                            end: start.addingTimeInterval(440), source: .appWatch,
                            bundleId: "com.anthropic.claude")
    let rec = SessionRecorder(fs: fs, effortfulAt: { _ in true })
    for c in counts { rec.push(counts: c) }
    let session = rec.finish(
        startedAt: start,
        device: DeviceInfo(name: Vertex.deviceName, sps: Int(fs), firmware: "v4"),
        activities: [span],
        markers: [Marker(kind: .stressed, at: start.addingTimeInterval(300), note: "stuck")],
        synthetic: true, syntheticNote: syntheticNote)
    return rollUp(sessions: [session], markers: session.markers, date: start)
}
