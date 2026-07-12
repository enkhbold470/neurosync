//
//  ContentView.swift
//  neurosync
//
//  NeuroSync — the macOS instrument for the NeuroFocus Vertex v4 insert.
//
//  There is no demo mode and no sample data. With no board on a head this window shows a flat
//  line and says so. That is not a missing feature; it is the whole claim.
//    — Manifesto II: "Every demo is a real brain, in real time. No simulations dressed as data."
//

import SwiftUI

struct ContentView: View {
    @State private var model = VertexModel()

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)

            Group {
                if model.isConnected {
                    Instrument(model: model)
                } else {
                    ConnectView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SpecStrip(snap: model.snap)
        }
        .background(Ink.bg)
        .frame(minWidth: 1040, minHeight: 700)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Header

private struct Header: View {
    let model: VertexModel

    var body: some View {
        HStack(spacing: 14) {
            Text("NEUROSYNC")
                .font(.data(12, .bold))
                .tracking(3)
                .foregroundStyle(Ink.text)

            Text("VERTEX v4")
                .font(.data(9))
                .tracking(1.2)
                .foregroundStyle(Ink.muted)

            Spacer()

            if model.isConnected, let info = model.snap.info {
                RatePicker(current: info.sps) { model.setRate(index: $0) }
            }

            StatusPip(state: model.state)

            if model.isConnected {
                Button("Disconnect") { model.disconnect() }
                    .buttonStyle(InstrumentButton())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Ink.bg)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.rule), alignment: .bottom)
    }
}

private struct StatusPip: View {
    let state: LinkState

    private var text: String {
        switch state {
        case .idle: return "NO DEVICE"
        case .bluetoothOff: return "BLUETOOTH OFF"
        case .unauthorized: return "BLUETOOTH DENIED"
        case .scanning: return "SCANNING"
        case .connecting: return "CONNECTING"
        case .interrogating: return "READING BOARD"
        case .streaming: return "LIVE"
        case .failed: return "FAULT"
        }
    }

    private var color: Color {
        switch state {
        case .streaming: return Ink.amber
        case .failed, .unauthorized, .bluetoothOff: return Ink.warn
        default: return Ink.muted
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.data(9, .semibold))
                .tracking(1.2)
                .foregroundStyle(color)
        }
    }
}

/// Rates below 175 SPS are offered but marked — the app will refuse to score on them and will
/// say why. Hiding them would hide the reason.
private struct RatePicker: View {
    let current: Int
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Vertex.rateLadder.enumerated()), id: \.offset) { idx, sps in
                let ok = focusFeasibility(fs: Double(sps)).ok
                let isCurrent = sps == current
                Button {
                    onPick(idx)
                } label: {
                    Text("\(sps)")
                        .font(.data(9, isCurrent ? .bold : .regular))
                        .foregroundStyle(
                            isCurrent ? Ink.bg : (ok ? Ink.dim : Ink.muted.opacity(0.55))
                        )
                        .frame(width: 42, height: 22)
                        .background(isCurrent ? Ink.amber : Color.clear)
                }
                .buttonStyle(.plain)
                .help(ok
                      ? "\(sps) SPS — focus score is defensible"
                      : (focusFeasibility(fs: Double(sps)).reason ?? ""))
            }
        }
        .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
    }
}

// MARK: - Disconnected

private struct ConnectView: View {
    let model: VertexModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            ScopeView(samples: [], live: false)
                .frame(height: 90)
                .frame(maxWidth: 420)

            VStack(spacing: 8) {
                Text("NO DEVICE")
                    .font(.data(13, .bold))
                    .tracking(3)
                    .foregroundStyle(Ink.text)

                Text(detail)
                    .font(.label(12))
                    .foregroundStyle(Ink.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let why) = model.state {
                Text(why)
                    .font(.label(11))
                    .foregroundStyle(Ink.warn)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canScan {
                Button(scanning ? "Scanning…" : "Connect to Vertex") { model.connect() }
                    .buttonStyle(InstrumentButton())
                    .disabled(scanning)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: Bool {
        model.state == .scanning || model.state == .connecting
    }

    private var canScan: Bool {
        switch model.state {
        case .bluetoothOff, .unauthorized: return false
        default: return true
        }
    }

    private var detail: String {
        switch model.state {
        case .bluetoothOff:
            return "Bluetooth is off. Turn it on to reach the board."
        case .unauthorized:
            return "macOS denied Bluetooth access. Grant it in System Settings ▸ Privacy & Security ▸ Bluetooth."
        default:
            return "This window shows no numbers until a Vertex board is streaming from a head. There is no demo mode. Looking for \(Vertex.deviceName)."
        }
    }
}

// MARK: - Connected

private struct Instrument: View {
    let model: VertexModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                if let gate = model.blockingGate {
                    GateBanner(gate: gate) {
                        // Index 3 == 175 SPS, the lowest defensible rate.
                        model.setRate(index: 3)
                    }
                }

                Panel(title: "SCOPE", trailing: fsLabel) {
                    ScopeView(samples: model.snap.waveform, live: model.metrics.signalOk)
                        .frame(height: 176)
                }

                Panel(title: "SPECTRUM", trailing: "Welch · Hann · 75% overlap") {
                    SpectrumView(
                        psd: model.metrics.psd,
                        alphaPeak: model.metrics.alphaPeak,
                        live: model.metrics.signalOk
                    )
                    .frame(height: 150)
                }

                if !model.focusHistory.isEmpty {
                    Panel(title: "FOCUS — THIS SESSION", trailing: "flow line 60") {
                        Sparkline(
                            values: model.focusHistory,
                            color: Ink.amber,
                            range: 0...100,
                            reference: flowThreshold
                        )
                        .frame(height: 56)
                    }
                }

                Spacer(minLength: 0)
            }

            VStack(spacing: 14) {
                FocusPanel(
                    metrics: model.metrics,
                    withheld: model.blockingGate != nil,
                    onRecalibrate: { model.recalibrate() }
                )
                BergerPanel(
                    metrics: model.metrics,
                    alphaHistory: model.alphaHistory,
                    live: model.metrics.signalOk
                )
                SignalPanel(snap: model.snap) { model.requestDiag() }
                Spacer(minLength: 0)
            }
            .frame(width: 340)
        }
        .padding(14)
    }

    private var fsLabel: String {
        model.snap.fs > 0
            ? "\(Int(model.snap.fs)) SPS · 1–45 Hz band-pass"
            : "waiting for board"
    }
}

#Preview {
    ContentView()
}
