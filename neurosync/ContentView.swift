//
//  ContentView.swift
//  neurosync
//
//  NeuroSync — the macOS instrument for the NeuroFocus Vertex v4 insert.
//
//  There is no demo mode and no sample data. With no board on a head this window shows a flat
//  line and says so. That is not a missing feature; it is the whole eclaim.
//    — Manifesto II: "Every demo is a real brain, in real time. No simulations dressed as data."
//

import SwiftUI

enum Surface: String, CaseIterable {
    case live = "LIVE"
    case day = "DAY"
}

struct ContentView: View {
    /// Injected by the App so the window and the menu bar share one source of truth.
    let model: VertexModel
    let days: DayModel

    @State private var surface: Surface = .live

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model, days: days, surface: $surface)

            if model.nudge != .none {
                NudgeBanner(level: model.nudge)
            }

            Group {
                switch surface {
                case .live:
                    if model.isConnected {
                        Instrument(model: model)
                    } else {
                        ConnectView(model: model)
                    }
                case .day:
                    DayView(model: days)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SpecStrip(snap: model.snap)
        }
        .background(Ink.bg)
        .frame(minWidth: 1120, minHeight: 760)
        .preferredColorScheme(.dark)
        .task {
            // The live model records through the SAME store the Day view reads. It is handed over
            // here rather than constructed inside VertexModel, so the link has no way to reach the
            // filesystem on its own.
            model.store = days.store
            model.onSessionWritten = { days.load() }
        }
    }
}

// MARK: - Nudge banner

/// The on-screen twin of the Dock badge: when the live score has stayed deep below your baseline,
/// it says so, and says what to do about it. Only appears on a trustworthy, sustained slump.
private struct NudgeBanner: View {
    let level: FocusNudge.Level

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: level.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.bg)
            Text(level == .walk ? "CRASHING OUT" : "FOCUS LOW")
                .font(.data(12, .bold))
                .tracking(1.6)
                .foregroundStyle(Ink.bg)
            Text(level.message ?? "")
                .font(.label(13))
                .foregroundStyle(Ink.bg.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(level == .walk ? Ink.warn : Ink.amber)
    }
}

// MARK: - Header

private struct Header: View {
    let model: VertexModel
    let days: DayModel
    @Binding var surface: Surface

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

            SurfacePicker(surface: $surface)

            Spacer()

            // Self-report. The ONLY place stress and anxiety enter this app — you say them, the
            // instrument records that you said them, and nothing pretends to have measured them.
            if surface == .live {
                MarkerRow(model: model, days: days)
            }

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

private struct SurfacePicker: View {
    @Binding var surface: Surface

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Surface.allCases, id: \.self) { s in
                Button {
                    surface = s
                } label: {
                    Text(s.rawValue)
                        .font(.data(11, surface == s ? .bold : .regular))
                        .tracking(1.2)
                        .foregroundStyle(surface == s ? Ink.bg : Ink.dim)
                        .frame(width: 52, height: 26)
                        .background(surface == s ? Ink.amber : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous)
            .strokeBorder(Ink.rule, lineWidth: 1))
    }
}

/// One tap per feeling. Written to markers.jsonl with `source: "self-reported"`, and into the live
/// session record if one is open.
private struct MarkerRow: View {
    let model: VertexModel
    let days: DayModel

    private let kinds: [MarkerKind] = [.stressed, .anxious, .breakTaken, .walk, .coffee]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(kinds, id: \.self) { k in
                Button {
                    model.mark(k)
                    days.load()
                } label: {
                    Image(systemName: k.glyph)
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.dim)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .help("Log \(k.label.lowercased()) — self-reported, and recorded as such. One around-ear channel cannot measure stress or anxiety, so this is you telling the instrument, not the instrument telling you.")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous)
            .strokeBorder(Ink.rule, lineWidth: 1))
        .disabled(!days.hasLocation)
        .opacity(days.hasLocation ? 1 : 0.35)
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
                        .font(.data(11, isCurrent ? .bold : .regular))
                        .foregroundStyle(
                            isCurrent ? Ink.bg : (ok ? Ink.dim : Ink.muted.opacity(0.55))
                        )
                        .frame(width: 46, height: 26)
                        .background(isCurrent ? Ink.amber : Color.clear)
                }
                .buttonStyle(.plain)
                .help(ok
                      ? "\(sps) SPS — focus score is defensible"
                      : (focusFeasibility(fs: Double(sps)).reason ?? ""))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous)
            .strokeBorder(Ink.rule, lineWidth: 1))
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
    ContentView(model: VertexModel(), days: DayModel())
}
