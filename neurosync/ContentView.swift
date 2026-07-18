//
//  ContentView.swift
//  neurosync
//
//  NeuroSync — the macOS instrument for the NeuroFocus Vertex v4 insert.
//
//  There is no demo mode and no sample data. With no board on a head this window shows a flat
//  line and says so — you only see a number once the signal is real. That restraint is the point.
//    — Manifesto II: "Every demo is a real brain, in real time."
//

import SwiftUI
import AppKit

enum Surface: String, CaseIterable {
    case live = "LIVE"
    case day = "DAY"

    var symbol: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .day:  return "chart.bar.xaxis"
        }
    }
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
        .task {
            // The live model records through the SAME store the Day view reads. It is handed over
            // here rather than constructed inside VertexModel, so the link has no way to reach the
            // filesystem on its own.
            model.store = days.store
            model.onSessionWritten = { days.load() }
        }
    }
}

// MARK: - Brand mark

/// The logo, as a small rounded badge. Self-contained (dark tile, light mark) so it reads on any
/// appearance without a light/dark swap.
struct BrandMark: View {
    var size: CGFloat = 22
    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityLabel("NeuroSync")
    }
}

// MARK: - Nudge banner

/// The on-screen twin of the Dock badge: when the live score has stayed deep below your baseline,
/// it says so — gently, and with a way back. Recovery, never a scolding.
private struct NudgeBanner: View {
    let level: FocusNudge.Level

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: level.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ink.onAccent)
            Text(level == .walk ? "TIME TO RESET" : "FOCUS DIPPED")
                .font(.data(12, .bold))
                .tracking(1.6)
                .foregroundStyle(Ink.onAccent)
            Text(level.message ?? "")
                .font(.label(13))
                .foregroundStyle(Ink.onAccent.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
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
        HStack(spacing: Space.lg) {
            BrandMark(size: 24)

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

            // Self-report. The ONLY place stress and anxiety enter this app — you say them,
            // the instrument records that you said them, nothing pretends to have measured them.
            if surface == .live {
                MarkerRow(model: model, days: days)
            }

            if model.isConnected, let info = model.snap.info {
                RatePicker(current: info.sps) { model.setRate(index: $0) }
            }

            StatusPip(state: model.state)

            if model.isConnected {
                Button {
                    model.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .buttonStyle(InstrumentButton())
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .glassControl(radius: 0)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Ink.rule), alignment: .bottom)
    }
}

private struct SurfacePicker: View {
    @Binding var surface: Surface

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Surface.allCases, id: \.self) { s in
                Button {
                    surface = s
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: s.symbol).font(.system(size: 9, weight: .semibold))
                        Text(s.rawValue).tracking(1.1)
                    }
                    .font(.data(11, surface == s ? .bold : .medium))
                    .foregroundStyle(surface == s ? Ink.onAccent : Ink.dim)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(surface == s ? Ink.amber : Color.clear,
                                in: RoundedRectangle(cornerRadius: Ink.radius - 2, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Ink.rule.opacity(0.6), in: RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
    }
}

/// One tap per feeling. Written to markers.jsonl with `source: "self-reported"`, and into the live
/// session record if one is open.
private struct MarkerRow: View {
    let model: VertexModel
    let days: DayModel

    private let kinds: [MarkerKind] = [.stressed, .anxious, .breakTaken, .walk, .coffee]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(kinds, id: \.self) { k in
                Button {
                    model.mark(k)
                    days.load()
                } label: {
                    Image(systemName: k.glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.dim)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Log \(k.label.lowercased()) — self-reported, and recorded as such. One around-ear channel cannot measure stress or anxiety, so this is you telling the instrument, not the instrument telling you.")
            }
        }
        .padding(.horizontal, 2)
        .background(Ink.rule.opacity(0.6), in: RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
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

    private var symbol: String {
        switch state {
        case .streaming: return "dot.radiowaves.left.and.right"
        case .scanning, .connecting, .interrogating: return "antenna.radiowaves.left.and.right"
        case .bluetoothOff: return "bolt.slash"
        case .unauthorized: return "hand.raised"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "powersleep"
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
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.data(9, .semibold))
                .tracking(1.2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(color.opacity(0.12), in: Capsule(style: .continuous))
    }
}

/// Rates below 175 SPS are offered but marked — the app will refuse to score on them and will
/// say why. Hiding them would hide the reason.
private struct RatePicker: View {
    let current: Int
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Vertex.rateLadder.enumerated()), id: \.offset) { idx, sps in
                let ok = focusFeasibility(fs: Double(sps)).ok
                let isCurrent = sps == current
                Button {
                    onPick(idx)
                } label: {
                    Text("\(sps)")
                        .font(.data(11, isCurrent ? .bold : .regular))
                        .foregroundStyle(
                            isCurrent ? Ink.onAccent : (ok ? Ink.dim : Ink.muted.opacity(0.55))
                        )
                        .frame(width: 44, height: 26)
                        .background(isCurrent ? Ink.amber : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Ink.radius - 2, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(ok
                      ? "\(sps) SPS — focus score is defensible"
                      : (focusFeasibility(fs: Double(sps)).reason ?? ""))
            }
        }
        .padding(2)
        .background(Ink.rule.opacity(0.6), in: RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
    }
}

// MARK: - Disconnected — the connect hero

private struct ConnectView: View {
    let model: VertexModel

    var body: some View {
        VStack(spacing: Space.xxl) {
            Spacer()

            BrandMark(size: 92)

            VStack(spacing: Space.sm) {
                Text("Protect your deep work.")
                    .font(.label(20, .semibold))
                    .foregroundStyle(Ink.text)
                Text("Put on the Vertex band and connect. You'll see your focus the moment it's reading a real signal — and nothing before it is.")
                    .font(.label(13))
                    .foregroundStyle(Ink.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A quiet, honest scope: flat until a real signal arrives.
            ScopeView(samples: [], live: false)
                .frame(height: 84)
                .frame(maxWidth: 420)
                .padding(Space.md)
                .background(Ink.plotBacking, in: RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
                .glassCard(radius: Ink.radiusCard)

            StatusLine(state: model.state)

            if case .failed(let why) = model.state {
                Text(why)
                    .font(.label(11))
                    .foregroundStyle(Ink.warn)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryAction

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxl)
    }

    @ViewBuilder private var primaryAction: some View {
        switch model.state {
        case .bluetoothOff, .unauthorized:
            Button {
                openBluetoothSettings()
            } label: {
                Label("Open Bluetooth Settings", systemImage: "gearshape")
            }
            .buttonStyle(InstrumentButton(prominent: true, size: .large))
        default:
            Button {
                model.connect()
            } label: {
                HStack(spacing: 8) {
                    if scanning {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Connect to Vertex")
                    }
                }
            }
            .buttonStyle(InstrumentButton(prominent: true, size: .large))
            .disabled(scanning)
        }
    }

    private var scanning: Bool {
        model.state == .scanning || model.state == .connecting || model.state == .interrogating
    }

    private func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The honest current status, as a symbol + one line — reads in a glance.
private struct StatusLine: View {
    let state: LinkState

    private var text: String {
        switch state {
        case .bluetoothOff: return "Bluetooth is off. Turn it on to reach the board."
        case .unauthorized: return "macOS denied Bluetooth. Grant it in System Settings ▸ Privacy & Security ▸ Bluetooth."
        case .scanning, .connecting: return "Looking for \(Vertex.deviceName)…"
        case .interrogating: return "Reading the board…"
        case .failed: return "Something went wrong. Try again."
        default: return "Looking for \(Vertex.deviceName). No demo mode — this stays flat until a real signal arrives."
        }
    }

    private var symbol: String {
        switch state {
        case .bluetoothOff: return "bolt.slash"
        case .unauthorized: return "hand.raised"
        case .scanning, .connecting, .interrogating: return "antenna.radiowaves.left.and.right"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.dim)
            Text(text)
                .font(.label(12))
                .foregroundStyle(Ink.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Connected

private struct Instrument: View {
    let model: VertexModel

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            GlassGroup(spacing: Space.lg) {
                VStack(spacing: Space.lg) {
                    if let gate = model.blockingGate {
                        GateBanner(gate: gate) {
                            // Index 3 == 175 SPS, the lowest defensible rate.
                            model.setRate(index: 3)
                        }
                    }

                    Panel(title: "SCOPE", symbol: "waveform", trailing: fsLabel) {
                        ScopeView(samples: model.snap.waveform, live: model.metrics.signalOk)
                            .frame(height: 176)
                            .plotInset()
                    }

                    Panel(title: "SPECTRUM", symbol: "waveform.path.ecg", trailing: "Welch · Hann · 75% overlap") {
                        SpectrumView(
                            psd: model.metrics.psd,
                            alphaPeak: model.metrics.alphaPeak,
                            live: model.metrics.signalOk
                        )
                        .frame(height: 150)
                        .plotInset()
                    }

                    if !model.focusHistory.isEmpty {
                        Panel(title: "FOCUS — THIS SESSION", symbol: "chart.line.uptrend.xyaxis", trailing: "flow line 60") {
                            Sparkline(
                                values: model.focusHistory,
                                color: Ink.amber,
                                range: 0...100,
                                reference: flowThreshold
                            )
                            .frame(height: 56)
                            .plotInset()
                        }
                    }

                    Spacer(minLength: 0)
                }
            }

            GlassGroup(spacing: Space.lg) {
                VStack(spacing: Space.lg) {
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
            }
            .frame(width: 340)
        }
        .padding(Space.lg)
    }

    private var fsLabel: String {
        model.snap.fs > 0
            ? "\(Int(model.snap.fs)) SPS · 1–45 Hz band-pass"
            : "waiting for board"
    }
}

/// A quiet solid inset behind a Canvas plot so traces stay crisp over glass.
extension View {
    func plotInset() -> some View {
        self.padding(Space.sm)
            .background(Ink.plotBacking, in: RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
    }
}

#Preview {
    ContentView(model: VertexModel(), days: DayModel())
}
