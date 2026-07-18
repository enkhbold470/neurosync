//
//  MenuBar.swift
//  neurosync
//

import SwiftUI

// MARK: - Menu bar

/// The ambient readout. This is the most dangerous surface in the app: a number in the menu bar
/// is glanced at and believed, with none of the context the window carries. So it obeys the same
/// gates, and when any of them is closed it shows a dash — never a stale or ungated figure.
struct MenuBarLabel: View {
    let model: VertexModel

    var body: some View {
        HStack(spacing: 4) {
            Image("MenuBarIcon")
                .renderingMode(.template)
            Text(model.menuBarValue)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }
}

struct MenuBarPanel: View {
    let model: VertexModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("NEUROFOCUS")
                    .font(.data(10, .bold))
                    .tracking(1.6)
                Spacer()
                Text(model.menuBarState)
                    .font(.data(9, .semibold))
                    .tracking(1)
                    .foregroundStyle(model.blockingGate == nil && model.isConnected
                                     ? Ink.amber : Ink.muted)
            }

            Divider()

            if let gate = model.blockingGate {
                VStack(alignment: .leading, spacing: 3) {
                    Text(gate.title)
                        .font(.data(9, .bold))
                        .tracking(1)
                        .foregroundStyle(gate.kind == .calibrating || gate.kind == .warmup
                                         ? Ink.amber : Ink.warn)
                    Text(gate.detail)
                        .font(.label(11))
                        .foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.isConnected {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(model.metrics.focus.rounded()))")
                        .font(.data(30, .bold))
                    Text("%")
                        .font(.data(13))
                        .foregroundStyle(Ink.muted)
                    Spacer()
                    Text(model.metrics.inFlow ? "IN FLOW" : "BELOW FLOW LINE")
                        .font(.data(9, .semibold))
                        .tracking(1)
                        .foregroundStyle(model.metrics.inFlow ? Ink.amber : Ink.muted)
                }
                Text("50 = your own baseline, this session.")
                    .font(.label(10))
                    .foregroundStyle(Ink.muted)
            } else {
                Text("No board. This shows a number only while a Vertex is streaming from a head.")
                    .font(.label(11))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            FocusBlockSection(model: model)

            Divider()

            HStack(spacing: 8) {
                if model.isConnected {
                    Button { model.recalibrate() } label: { Label("Recalibrate", systemImage: "arrow.clockwise") }
                    Button { model.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                } else {
                    Button { model.connect() } label: { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }
                }
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: { Label("Quit", systemImage: "power") }
            }
            .font(.label(11))
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Focus block

/// Start a block, watch it run, read its recap — all from the live model only. A block is the honest
/// source of the `effortful` context the drift intervention needs; it is never inferred from signal.
struct FocusBlockSection: View {
    let model: VertexModel

    private static let presets = [15, 25, 50]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FOCUS BLOCK")
                    .font(.data(9, .bold))
                    .tracking(1.2)
                Spacer()
                if model.driftAlert {
                    Label("DRIFTING", systemImage: "cloud.fill")
                        .font(.data(9, .semibold))
                        .tracking(1)
                        .foregroundStyle(Ink.warn)
                }
            }

            if let p = model.blockProgress {
                // Running.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.clock(p.elapsed))
                        .font(.data(20, .bold))
                    Text("/ \(Self.clock(p.planned))")
                        .font(.data(11))
                        .foregroundStyle(Ink.muted)
                    Spacer()
                    Button("End") { model.endBlock() }
                }
                Text(model.blockDriftCatches == 1
                     ? "1 drift caught"
                     : "\(model.blockDriftCatches) drifts caught")
                    .font(.label(10))
                    .foregroundStyle(Ink.muted)
            } else if let r = model.lastRecap {
                // Just ended — the recap.
                RecapView(recap: r)
                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.self) { m in
                        Button("\(m)m") { model.startBlock(minutes: m) }
                            .disabled(!model.isConnected)
                    }
                    Spacer()
                }
                .font(.label(11))
            } else {
                // Idle.
                Text(model.isConnected
                     ? "Declare a block you mean to concentrate in. A subtle nudge if you drift."
                     : "Connect a board to run a focus block.")
                    .font(.label(11))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.self) { m in
                        Button("\(m)m") { model.startBlock(minutes: m) }
                            .disabled(!model.isConnected)
                    }
                    Spacer()
                }
                .font(.label(11))
            }
        }
    }

    /// mm:ss.
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One honest end-of-block summary. Every number is counted from the real DSP epoch stream.
struct RecapView: View {
    let recap: BlockRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                stat(String(format: "%.0f", recap.minutesFocused), "MIN FOCUSED")
                stat("\(recap.driftCatches)", "DRIFTS")
                stat(String(format: "%.0f", recap.longestFocusedStretchMin), "LONGEST MIN")
            }
            Text(recap.withheldSeconds > 0
                 ? String(format: "%.0f%% coverage — %d s withheld and not counted as focus.",
                          recap.coverage * 100, recap.withheldSeconds)
                 : "Full coverage.")
                .font(.label(10))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.data(18, .bold))
            Text(label).font(.data(8, .semibold)).tracking(0.8).foregroundStyle(Ink.muted)
        }
    }
}
