//
//  Snapshots.swift
//  neurosyncTests
//
//  Renders the real SwiftUI views to PNG so the interface can be reviewed without a board
//  and without screen-recording permission. The metrics fed in are produced by running the
//  REAL DSP over a synthetic waveform — the fixture is the input signal, never the output.
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

/// Metrics from the real engine, driven by a strong 10 Hz alpha — an eyes-closed Berger state.
private func liveMetrics() -> FocusMetrics {
    let fs = 175.0
    let e = FocusEngine(fs: fs, options: FocusOptions(baselineEngagement: 0.9))
    for i in 0..<Int(8 * fs) {
        let t = Double(i) / fs
        let uv = 6 * sin(2 * .pi * 6 * t) + 22 * sin(2 * .pi * 10 * t) + 9 * sin(2 * .pi * 20 * t)
        e.push(counts: Int32((uv / countsToUv(1.0)).rounded()))
    }
    return e.metrics
}

@MainActor
@Test func snapshotDisconnected() throws {
    // The honest hero state: no board, no numbers, a flat line.
    let path = try render(ContentView(model: VertexModel()), size: CGSize(width: 1100, height: 720),
                          to: "01-disconnected.png")
    print("SNAPSHOT \(path)")
    #expect(FileManager.default.fileExists(atPath: path))
}

@MainActor
@Test func snapshotInstrument() throws {
    let m = liveMetrics()

    let view = HStack(alignment: .top, spacing: 14) {
        VStack(spacing: 14) {
            Panel(title: "SCOPE", trailing: "175 SPS · 1–45 Hz band-pass") {
                ScopeView(samples: Array(repeating: 0, count: 0), live: false)
                    .frame(height: 150)
            }
            Panel(title: "SPECTRUM", trailing: "Welch · Hann · 75% overlap") {
                SpectrumView(psd: m.psd, alphaPeak: m.alphaPeak, live: true)
                    .frame(height: 150)
            }
            Spacer(minLength: 0)
        }
        VStack(spacing: 14) {
            FocusPanel(metrics: m, withheld: false, onRecalibrate: {})
            BergerPanel(metrics: m, alphaHistory: (0..<120).map { 20 + 8 * sin(Double($0) / 9) },
                        live: true)
            Spacer(minLength: 0)
        }
        .frame(width: 340)
    }
    .padding(14)
    .background(Ink.bg)

    let path = try render(view, size: CGSize(width: 1000, height: 700), to: "02-instrument.png")
    print("SNAPSHOT \(path)")
    #expect(m.alphaPeak != nil)
}

@MainActor
@Test func snapshotGates() throws {
    // The three refusals, which are the product.
    let rate = Gate(
        title: "SCORE WITHHELD — SAMPLE RATE",
        detail: focusFeasibility(fs: 90).reason ?? "",
        kind: .rate)
    let signal = Gate(
        title: "NO BIOSIGNAL",
        detail: "0.31 µV RMS — below the 1.5 µV noise floor. The electrode is not making skin contact.",
        kind: .signal)
    let cal = Gate(
        title: "CALIBRATING BASELINE",
        detail: "12 s of good signal remaining. 50 will mean YOUR baseline.",
        kind: .calibrating)

    let view = VStack(spacing: 12) {
        GateBanner(gate: rate, onFixRate: {})
        GateBanner(gate: signal)
        GateBanner(gate: cal)
    }
    .padding(18)
    .background(Ink.bg)

    let path = try render(view, size: CGSize(width: 760, height: 280), to: "03-gates.png")
    print("SNAPSHOT \(path)")
    #expect(!rate.detail.isEmpty)
}
