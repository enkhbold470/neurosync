//
//  Panels.swift
//  neurosync
//

import SwiftUI

// MARK: - Gate banner

/// The gates are not error states — they are the product. A score that appears when the
/// electrode is off a head is worth nothing, so we say plainly why we are withholding it.
struct GateBanner: View {
    let gate: VertexModel.Gate
    var onFixRate: (() -> Void)?

    private var tint: Color {
        switch gate.kind {
        case .rate, .signal: return Ink.warn
        case .calibrating, .warmup: return Ink.amber
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(tint)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(gate.title)
                    .font(.data(10, .bold))
                    .tracking(1.4)
                    .foregroundStyle(tint)
                Text(gate.detail)
                    .font(.label(12))
                    .foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if gate.kind == .rate, let onFixRate {
                Button("Set 175 SPS", action: onFixRate)
                    .buttonStyle(InstrumentButton())
            }
        }
        .padding(12)
        .background(tint.opacity(0.06))
        .overlay(Rectangle().strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }
}

// MARK: - Focus

struct FocusPanel: View {
    let metrics: FocusMetrics
    let withheld: Bool
    let onRecalibrate: () -> Void

    var body: some View {
        Panel(title: "FOCUS", trailing: "β / (α + θ)") {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Ink.rule, lineWidth: 10)
                    if !withheld {
                        Circle()
                            .trim(from: 0, to: metrics.focus / 100)
                            .stroke(Ink.amber, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.35), value: metrics.focus)
                    }

                    if withheld {
                        Text("—")
                            .font(.data(38, .semibold))
                            .foregroundStyle(Ink.muted)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(Int(metrics.focus.rounded()))")
                                .font(.data(40, .bold))
                                .foregroundStyle(Ink.text)
                                .contentTransition(.numericText())
                            Text("%")
                                .font(.data(16))
                                .foregroundStyle(Ink.muted)
                        }
                    }
                }
                .frame(width: 132, height: 132)
                .frame(maxWidth: .infinity)

                if withheld {
                    Text("No score. The gate above must clear first.")
                        .font(.label(11))
                        .foregroundStyle(Ink.muted)
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(metrics.inFlow ? Ink.amber : Ink.muted)
                            .frame(width: 5, height: 5)
                        Text(metrics.inFlow ? "IN FLOW" : "BELOW FLOW LINE")
                            .font(.data(10, .semibold))
                            .tracking(1.2)
                            .foregroundStyle(metrics.inFlow ? Ink.amber : Ink.muted)
                        Spacer()
                        Button("Recalibrate", action: onRecalibrate)
                            .buttonStyle(InstrumentButton())
                    }
                }

                Divider().overlay(Ink.rule)

                // The honesty block. This stays on screen; it is not a tooltip.
                VStack(alignment: .leading, spacing: 3) {
                    Text("50 = YOUR OWN baseline, frozen after 20 s.")
                    Text("Not comparable between people. Valid within this session only.")
                    Text("β overlaps jaw and neck EMG — clenching raises this exactly like concentrating does.")
                }
                .font(.label(10))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Berger / alpha

/// The Berger test — Hans Berger, 1929: occipital alpha rises when the eyes close.
///
/// This is the honest proof that the electrode is on a brain and not on a table, and unlike
/// the focus score it is valid from 45 SPS up (it only needs 13 Hz of bandwidth). It is the
/// thing to put on camera.
struct BergerPanel: View {
    let metrics: FocusMetrics
    let alphaHistory: [Double]
    let live: Bool

    private var alphaPower: Double { metrics.bands[.alpha] ?? 0 }

    var body: some View {
        Panel(title: "ALPHA — BERGER TEST", trailing: "8–13 Hz") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 20) {
                    Readout(
                        label: "PEAK",
                        value: metrics.alphaPeak.map { String(format: "%.1f", $0) } ?? "—",
                        unit: "Hz",
                        emphasis: true
                    )
                    Readout(
                        label: "POWER",
                        value: live ? String(format: "%.1f", alphaPower) : "—",
                        unit: "µV²/Hz"
                    )
                }

                Sparkline(values: alphaHistory, color: Ink.amber)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.02))

                Text("Close your eyes for 10 s. Alpha should rise and the peak should settle near 10 Hz. If it doesn't, the electrode isn't reading a brain — and nothing else on this screen means anything.")
                    .font(.label(10))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Signal

struct SignalPanel: View {
    let snap: VertexSnapshot
    let onDiag: () -> Void

    var body: some View {
        Panel(title: "SIGNAL", trailing: snap.metrics.signalOk ? "CONTACT" : "NO CONTACT") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Readout(label: "RMS", value: String(format: "%.2f", snap.metrics.rmsUv), unit: "µV")
                    Readout(label: "BLINKS", value: "\(snap.metrics.blinks)")
                    Readout(label: "DROPPED", value: "\(snap.droppedFrames)")
                }

                if let d = snap.diag {
                    HStack(spacing: 6) {
                        Text("DIAG")
                            .font(.data(9, .semibold))
                            .foregroundStyle(Ink.muted)
                        Text(d.error ?? d.verdict)
                            .font(.data(10, .semibold))
                            .foregroundStyle(d.verdict == "OK" ? Ink.amber : Ink.warn)
                        Spacer()
                    }
                }

                HStack {
                    Text("Contact gate: > 1.5 µV RMS")
                        .font(.label(10))
                        .foregroundStyle(Ink.muted)
                    Spacer()
                    Button("Run DIAG", action: onDiag)
                        .buttonStyle(InstrumentButton())
                }
            }
        }
    }
}

// MARK: - Chrome

struct InstrumentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.data(10, .semibold))
            .tracking(0.8)
            .foregroundStyle(configuration.isPressed ? Ink.bg : Ink.amber)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Ink.amber : Color.clear)
            .overlay(Rectangle().strokeBorder(Ink.amber.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// The spec strip. Every line here is a claim, so every line here is checkable against the
/// board that is actually plugged in. `fs` is whatever the board reported — never assumed.
struct SpecStrip: View {
    let snap: VertexSnapshot

    var body: some View {
        HStack(spacing: 14) {
            item("single around-ear dry channel")
            dot()
            item("ADS1220 · 24-bit")
            dot()
            if let info = snap.info {
                item("\(info.fw) · \(info.sps) SPS · batch \(info.batch)")
            } else {
                item("no board")
            }
            dot()
            item("60 Hz notch")

            Spacer()

            // Manifesto VI — the interface layer is a commons. This is rung 2, not dev bloat.
            Text("bci-mcp — open protocol")
                .font(.data(9))
                .foregroundStyle(Ink.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Ink.bg)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.rule), alignment: .top)
    }

    private func item(_ s: String) -> some View {
        Text(s).font(.data(9)).foregroundStyle(Ink.muted)
    }
    private func dot() -> some View {
        Text("·").font(.data(9)).foregroundStyle(Ink.rule)
    }
}
