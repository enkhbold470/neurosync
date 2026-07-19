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

/// Start a block, watch it run, read its recap — all from the live model only. THE BLOCK NEEDS NO
/// HEADSET: it times you and watches your app context regardless. A board, when present, adds the
/// brain layer. A block is the honest source of `effortful`; it is never inferred from the signal.
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
                running(p)
            } else if let r = model.lastRecap {
                RecapView(recap: r)
                presetRow
            } else {
                Text("Start a block — NeuroSync keeps you on task, headset or not. Connect a Vertex to add the brain layer.")
                    .font(.label(11))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
                presetRow
            }
        }
    }

    @ViewBuilder private func running(_ p: (elapsed: TimeInterval, planned: TimeInterval)) -> some View {
        if let intention = model.blockIntention {
            Text(intention)
                .font(.label(12, .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.clock(p.elapsed))
                .font(.data(20, .bold))
            Text("/ \(Self.clock(p.planned))")
                .font(.data(11))
                .foregroundStyle(Ink.muted)
            Spacer()
            Button("End") { model.endBlock() }
        }
        // The live context line, or the drift message when one is up. Measured, never a brain claim.
        Text(model.driftAlert ? model.driftAlertMessage : liveContextLine)
            .font(.label(10))
            .foregroundStyle(model.driftAlert ? Ink.warn : Ink.muted)
            .fixedSize(horizontal: false, vertical: true)
        if !model.isConnected {
            Label("Connect a headset for the brain layer", systemImage: "antenna.radiowaves.left.and.right")
                .font(.label(10))
                .foregroundStyle(Ink.dim)
        }
    }

    /// e.g. "on task · Xcode — 18m on task, 2 slips". Only app-context facts.
    private var liveContextLine: String {
        let where_: String
        switch model.blockCurrentContext {
        case .onTask: where_ = "on task"
        case .away:   where_ = "away"
        case .neutral: where_ = "—"
        }
        let app = model.blockCurrentLabel.map { " · \($0)" } ?? ""
        let onTask = model.blockOnTaskSeconds / 60
        let slips = model.blockDriftCatches
        let tail = slips == 1 ? "1 slip" : "\(slips) slips"
        return "\(where_)\(app) — \(onTask)m on task, \(tail)"
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(Self.presets, id: \.self) { m in
                Button("\(m)m") { model.startBlock(minutes: m) }   // no headset required
            }
            Spacer()
        }
        .font(.label(11))
    }

    /// mm:ss.
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One honest end-of-block summary in TWO vocabularies that never mix. The behavioural half is
/// measured (time, apps) and always present; the brain half is a focus claim and appears ONLY when a
/// headset produced epochs. `recap.brain == nil` → there is no focus number to show, by construction.
struct RecapView: View {
    let recap: BlockRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Behavioural half — always. Measured facts, not a brain claim.
            HStack(spacing: 16) {
                stat(mins(recap.behavior.onTaskSeconds), "MIN ON TASK")
                stat("\(recap.behavior.slips)", recap.behavior.slips == 1 ? "SLIP" : "SLIPS")
                stat(mins(recap.behavior.longestOnTaskStretchSec), "LONGEST MIN")
            }

            if let brain = recap.brain {
                // Brain half — only with a headset. Separate words, separate row.
                Rectangle().fill(Ink.rule).frame(width: 160, height: 1).padding(.vertical, 1)
                HStack(spacing: 16) {
                    stat(mins(brain.focusedSeconds), "MIN FOCUSED")
                    stat(String(format: "%.0f%%", brain.coverage * 100), "COVERAGE")
                }
                if brain.withheldSeconds > 0 {
                    note(String(format: "%d s withheld — not counted as focus.", brain.withheldSeconds))
                }
            } else {
                note("No headset — this is your behaviour, not a focus score.")
            }
        }
    }

    private func mins(_ sec: Int) -> String { String(format: "%.0f", Double(sec) / 60) }

    private func note(_ s: String) -> some View {
        Text(s)
            .font(.label(10))
            .foregroundStyle(Ink.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.data(18, .bold))
            Text(label).font(.data(8, .semibold)).tracking(0.8).foregroundStyle(Ink.muted)
        }
    }
}
