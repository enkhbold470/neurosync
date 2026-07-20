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
    var cloud: ConvexCloud

    /// Held so the sign-in observer below can flush the backlog when auth flips on.
    @State private var syncController: CloudSyncController?

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model, days: days, cloud: cloud)

            if model.nudge != .none {
                NudgeBanner(level: model.nudge)
            }

            // One page: live focus + today + yesterday, with connect / board-pick / focus-block
            // controls folded in. Replaces the old LIVE/DAY split.
            SessionScreen(model: model, days: days)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            SpecStrip(snap: model.snap)
        }
        .background(Ink.bg)
        .frame(minWidth: 1120, minHeight: 760)
        // ONE task, keyed on auth state, so there is no race between wiring and the sign-in flush.
        // It runs on first appear (signedIn=false → syncPending is a guarded no-op) and again the
        // moment `signedIn` flips true — which is what mirrors the local backlog to the cloud. Without
        // keying on auth, a session recorded before sign-in would never upload until the NEXT one
        // sealed. Wiring (store handover + onSessionWritten) happens once, on the first run.
        .task(id: cloud.signedIn) {
            // The live model records through the SAME store the Day view reads. Handed over here so
            // the link has no way to reach the filesystem on its own.
            model.store = days.store

            if syncController == nil {
                let sync = CloudSyncController(store: days.store, uploader: cloud.uploader)
                syncController = sync
                model.onSessionWritten = {
                    days.load()
                    Task { await sync.syncPending() }
                }
            }
            // Opt-in cloud mirror. A true no-op unless a CONVEX_URL is configured AND a user is signed
            // in — the instrument stays local-first. Uploads local sessions, never synthetic ones.
            await syncController?.syncPending()
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
    var cloud: ConvexCloud

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

            Spacer()

            // Self-report. The ONLY place stress and anxiety enter this app — you say them,
            // the instrument records that you said them, nothing pretends to have measured them.
            MarkerRow(model: model, days: days)

            if model.isConnected, let info = model.snap.info {
                RatePicker(current: info.sps) { model.setRate(index: $0) }
            }

            StatusPip(state: model.state)

            CloudSyncButton(cloud: cloud)

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

// MARK: - Disconnected — the focus-block home

/// The front door when no board is streaming. The block is the point: it works with NO headset, so
/// this leads with "start a block", and offers connecting a Vertex as a secondary upgrade (the brain
/// layer). No fabricated number appears anywhere here — a headset-free block measures behaviour, not
/// brains.
private struct FocusHome: View {
    let model: VertexModel
    @State private var intention = ""

    private static let presets = [15, 25, 50]

    var body: some View {
        VStack(spacing: Space.xxl) {
            Spacer()

            BrandMark(size: 84)

            VStack(spacing: Space.sm) {
                Text("Protect your deep work.")
                    .font(.label(26, .bold))
                    .foregroundStyle(Ink.text)
                Text("A focus timer — no headset needed. Connect a Vertex to add the live brain layer.")
                    .font(.label(15))
                    .foregroundStyle(Ink.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Optional intention. Naming the work is itself a focus aid, and it heads the recap.
            TextField("What are you working on? (optional)", text: $intention)
                .textFieldStyle(.plain)
                .font(.label(14))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.vertical, 10)
                .padding(.horizontal, Space.md)
                .glassField(radius: Ink.radius)
                .onSubmit { model.startBlock(minutes: 25, intention: intention) }

            // The primary action: start a block. No headset, no account, no gate.
            HStack(spacing: Space.md) {
                ForEach(Self.presets, id: \.self) { m in
                    Button {
                        model.startBlock(minutes: m, intention: intention)
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(m)").font(.data(24, .bold))
                            Text("MIN").font(.data(9, .semibold)).tracking(1.6)
                        }
                        .frame(width: 84)
                    }
                    .buttonStyle(InstrumentButton(prominent: m == 25, size: .large))
                }
            }

            connectAffordance

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxl)
    }

    /// Secondary: connect a board for the brain layer. Adapts to the Bluetooth state, and surfaces a
    /// failure honestly, but never blocks starting a block.
    @ViewBuilder private var connectAffordance: some View {
        VStack(spacing: Space.sm) {
            switch model.state {
            case .bluetoothOff, .unauthorized:
                Button { openBluetoothSettings() } label: {
                    Label("Open Bluetooth Settings", systemImage: "gearshape")
                }
                .buttonStyle(InstrumentButton())
            case .scanning where !model.discoveredBoards.isEmpty:
                // Boards found — pick yours instead of the app grabbing whichever answered first.
                BoardPicker(boards: model.discoveredBoards,
                            onPick: { model.connect(to: $0) },
                            onRescan: { model.connect() })
            default:
                Button { model.connect() } label: {
                    HStack(spacing: 8) {
                        if scanning {
                            ProgressView().controlSize(.small)
                            Text(model.state == .scanning ? "Looking for boards…" : "Connecting…")
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Connect a headset for the brain layer")
                        }
                    }
                }
                .buttonStyle(InstrumentButton())
                .disabled(scanning)
            }

            if case .failed(let why) = model.state {
                Text(why)
                    .font(.label(11))
                    .foregroundStyle(Ink.warn)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

// MARK: - Board picker

/// Shown while scanning once one or more boards answer. You tap yours — the app never guesses when
/// several are powered on. The board you pick is remembered, so next time it connects silently.
struct BoardPicker: View {
    let boards: [DiscoveredBoard]
    let onPick: (UUID) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("SELECT YOUR BOARD")
                    .font(.data(10, .bold)).tracking(1.6).foregroundStyle(Ink.muted)
                Spacer()
                Text("\(boards.count) FOUND")
                    .font(.data(10, .semibold)).tracking(1.0).foregroundStyle(Ink.muted)
            }

            ForEach(boards) { b in
                Button { onPick(b.id) } label: {
                    HStack(spacing: Space.md) {
                        SignalBars(rssi: b.rssi)
                        Text(b.name)
                            .font(.data(13, .semibold))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                        Spacer(minLength: Space.md)
                        Text("\(b.rssi) dBm")
                            .font(.data(10))
                            .foregroundStyle(Ink.muted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Ink.amber)
                    }
                    .padding(.horizontal, Space.md)
                    .frame(height: 42)
                    .frame(maxWidth: .infinity)
                    .background(Ink.rule.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: Ink.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Ink.radius, style: .continuous)
                        .strokeBorder(Ink.rule, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Button { onRescan() } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(InstrumentButton())
        }
        .frame(width: 380)
    }
}

/// Four bars, filled by signal strength (RSSI in dBm; closer to 0 is stronger).
struct SignalBars: View {
    let rssi: Int
    private var level: Int {
        switch rssi {
        case (-55)...:        return 4
        case (-65)..<(-55):   return 3
        case (-75)..<(-65):   return 2
        default:              return 1
        }
    }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i <= level ? Ink.amber : Ink.rule)
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
        .frame(width: 20, height: 16, alignment: .bottom)
    }
}

// MARK: - A running block, headset-free

/// The main-window face of a block running with no board. Everything here is a MEASURED fact — time,
/// and which app you were in. There is no focus number, because there is no brain signal; the
/// closing line says so plainly. The whole view ticks because the model mutates the block each second.
private struct BlockLiveView: View {
    let model: VertexModel

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()

            if let intention = model.blockIntention {
                Text(intention)
                    .font(.label(18, .semibold))
                    .foregroundStyle(Ink.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Focus block")
                    .font(.label(15, .semibold))
                    .foregroundStyle(Ink.muted)
            }

            BlockRing(progress: fraction, elapsed: elapsed, planned: planned)

            HStack(spacing: 8) {
                Image(systemName: contextSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(contextColor)
                Text(model.driftAlert ? model.driftAlertMessage : contextLine)
                    .font(.label(13))
                    .foregroundStyle(model.driftAlert ? Ink.warn : Ink.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.xxl) {
                stat("\(model.blockOnTaskSeconds / 60)", "MIN ON TASK")
                stat("\(model.blockDriftCatches)", model.blockDriftCatches == 1 ? "SLIP" : "SLIPS")
            }

            Button { model.endBlock() } label: {
                Label("End block", systemImage: "stop.circle")
            }
            .buttonStyle(InstrumentButton(prominent: true, size: .large))

            if !model.isConnected {
                Label("No headset — this is your behaviour, not a focus score. Connect a Vertex to add the brain layer.",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .font(.label(11))
                    .foregroundStyle(Ink.dim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxl)
    }

    private var elapsed: TimeInterval { model.blockProgress?.elapsed ?? 0 }
    private var planned: TimeInterval { model.blockProgress?.planned ?? 1 }
    private var fraction: Double { planned > 0 ? Swift.min(1, elapsed / planned) : 0 }

    private var contextLine: String {
        let app = model.blockCurrentLabel.map { " · \($0)" } ?? ""
        switch model.blockCurrentContext {
        case .onTask:  return "On task\(app)"
        case .away:    return "Away\(app)"
        case .neutral: return model.blockCurrentLabel ?? "Watching your app context"
        }
    }

    private var contextSymbol: String {
        if model.driftAlert { return "cloud.fill" }
        switch model.blockCurrentContext {
        case .onTask:  return "checkmark.circle.fill"
        case .away:    return "arrow.uturn.backward.circle"
        case .neutral: return "circle.dashed"
        }
    }

    private var contextColor: Color {
        if model.driftAlert { return Ink.warn }
        return model.blockCurrentContext == .onTask ? Ink.amber : Ink.dim
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.data(34, .bold)).foregroundStyle(Ink.text).monospacedDigit()
            Text(label).font(.data(9, .semibold)).tracking(1.2).foregroundStyle(Ink.muted)
        }
    }
}

/// The elapsed / planned ring at the heart of a running block. A time fact, not a focus claim.
private struct BlockRing: View {
    let progress: Double
    let elapsed: TimeInterval
    let planned: TimeInterval

    var body: some View {
        ZStack {
            Circle().stroke(Ink.rule, lineWidth: 10)
            Circle()
                .trim(from: 0, to: Swift.max(0.001, progress))
                .stroke(Ink.amber, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text(clock(elapsed)).font(.data(42, .bold)).foregroundStyle(Ink.text).monospacedDigit()
                Text("/ \(clock(planned))").font(.data(13)).foregroundStyle(Ink.muted).monospacedDigit()
            }
        }
        .frame(width: 220, height: 220)
        .padding(Space.md)
        .glassCard(radius: 130)
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Swift.max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
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
    ContentView(model: VertexModel(), days: DayModel(), cloud: ConvexCloud())
}
