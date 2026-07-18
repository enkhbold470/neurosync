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
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.isConnected {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(model.metrics.focus.rounded()))")
                        .font(.data(30, .bold))
                    Text("%")
                        .font(.data(13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.metrics.inFlow ? "IN FLOW" : "BELOW FLOW LINE")
                        .font(.data(9, .semibold))
                        .tracking(1)
                        .foregroundStyle(model.metrics.inFlow ? Ink.amber : .secondary)
                }
                Text("50 = your own baseline, this session.")
                    .font(.label(10))
                    .foregroundStyle(.secondary)
            } else {
                Text("No board. This shows a number only while a Vertex is streaming from a head.")
                    .font(.label(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                if model.isConnected {
                    Button("Recalibrate") { model.recalibrate() }
                    Button("Disconnect") { model.disconnect() }
                } else {
                    Button("Connect") { model.connect() }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.label(11))
        }
        .padding(14)
        .frame(width: 280)
    }
}
