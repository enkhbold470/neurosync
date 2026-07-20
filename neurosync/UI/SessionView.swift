//
//  SessionView.swift
//  neurosync
//
//  The one-page main window (design import "NeuroFocus Mac App"). The liquid-glass / aurora look from
//  the mock, wired to REAL data: the focus number is the gated Pope β/(α+θ) score and shows "—" the
//  moment a gate closes or no headset is connected; the hour chart and yesterday card are computed
//  from trusted epochs only; the footer states the true hardware (one around-ear dry channel). No
//  fabricated number reaches this surface (Manifesto II). The mock's PO3·O1·Oz / 250 Hz / ADS1299 was
//  a design placeholder, not us.
//
//  `SessionView` is the pure, snapshot-testable display. `SessionScreen` wraps it with the aurora,
//  scrolling, and the live controls (connect a board, pick among boards, start/stop a focus block).
//

import SwiftUI
import AppKit

// MARK: - Aurora wallpaper

/// The soft amber+violet aurora behind the glass. Purely decorative — carries no data.
struct AuroraBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x17121F), Color(hex: 0x0D0B12), Color(hex: 0x08080A)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(hex: 0xF1B27A).opacity(0.22)).blur(radius: 90)
                .frame(width: 620, height: 560).offset(x: -240, y: -220)
            Circle().fill(Color(hex: 0x7C3AED).opacity(0.18)).blur(radius: 100)
                .frame(width: 720, height: 640).offset(x: 300, y: -120)
            Circle().fill(Color(hex: 0x5EEAD4).opacity(0.08)).blur(radius: 110)
                .frame(width: 560, height: 460).offset(x: 60, y: 320)
        }
        .ignoresSafeArea()
    }
}

// MARK: - The one page, live

/// The single main surface. Owns the live controls and feeds `SessionView` real values.
struct SessionScreen: View {
    let model: VertexModel
    let days: DayModel

    var body: some View {
        ZStack {
            AuroraBackground()
            if !days.hasLocation {
                grantFolder
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SessionView(
                            metrics: model.metrics, withheld: withheld, gateReason: gateReason,
                            sps: model.snap.info?.sps ?? Int(model.snap.fs),
                            title: title, subtitle: subtitle,
                            day: days.selected, yesterday: yesterday)
                        controls
                    }
                    .padding(24)
                }
            }
        }
    }

    // ── Live controls: connect / pick a board / start-stop a block ───────────
    @ViewBuilder private var controls: some View {
        if model.blockActive {
            HStack(spacing: 12) {
                Image(systemName: "timer").foregroundStyle(Ink.amber)
                Text(blockClock).font(.data(15, .bold)).foregroundStyle(.white).monospacedDigit()
                Text("/ \(model.blockProgress.map { clockMMSS($0.planned) } ?? "—")")
                    .font(.data(11)).foregroundStyle(Color(hex: 0xA2A0AB))
                Spacer()
                Button { model.endBlock() } label: { Label("End block", systemImage: "stop.circle") }
                    .buttonStyle(InstrumentButton(prominent: true))
            }
            .padding(16).glassPane()
        } else if model.isConnected {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Ink.amber)
                Text("Streaming live").font(.label(12)).foregroundStyle(Color(hex: 0xA2A0AB))
                Spacer()
                ForEach([15, 25, 50], id: \.self) { m in
                    Button("\(m)m") { model.startBlock(minutes: m) }
                        .buttonStyle(InstrumentButton())
                }
            }
            .padding(16).glassPane()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    switch model.state {
                    case .bluetoothOff, .unauthorized:
                        Button { openBluetoothSettings() } label: {
                            Label("Open Bluetooth Settings", systemImage: "gearshape")
                        }.buttonStyle(InstrumentButton())
                    default:
                        Button { model.connect() } label: {
                            Label(scanning ? "Looking for boards…" : "Connect a headset",
                                  systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .buttonStyle(InstrumentButton()).disabled(scanning)
                    }
                    Text("or start a focus block").font(.label(12)).foregroundStyle(Color(hex: 0x6F6D78))
                    Spacer()
                    ForEach([15, 25, 50], id: \.self) { m in
                        Button("\(m)m") { model.startBlock(minutes: m) }
                            .buttonStyle(InstrumentButton(prominent: m == 25))
                    }
                }
                if model.state == .scanning, !model.discoveredBoards.isEmpty {
                    BoardPicker(boards: model.discoveredBoards,
                                onPick: { model.connect(to: $0) },
                                onRescan: { model.connect() })
                }
                if case .failed(let why) = model.state {
                    Text(why).font(.label(11)).foregroundStyle(Ink.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16).glassPane()
        }
    }

    private var grantFolder: some View {
        VStack(spacing: 16) {
            Text("NO DATA FOLDER").font(.data(13, .bold)).tracking(3).foregroundStyle(.white)
            Text("NeuroSync writes plain JSON to ~/Desktop/\(Store.folderName). Grant the folder once and it's remembered.")
                .font(.label(12)).foregroundStyle(Color(hex: 0xA2A0AB))
                .multilineTextAlignment(.center).frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose folder…") { days.chooseFolder() }.buttonStyle(InstrumentButton())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Derived ──────────────────────────────────────────────────────────────
    private var withheld: Bool { !model.isConnected || model.blockingGate != nil }
    private var gateReason: String? {
        if model.isConnected, let g = model.blockingGate { return g.detail }
        if !model.isConnected {
            return model.blockActive
                ? "This block is timing your behaviour — connect a headset to add the live brain layer."
                : "Connect a headset for a live focus score, or start a focus block."
        }
        return nil
    }
    private var title: String {
        if model.blockActive { return model.blockIntention ?? "Focus block" }
        return model.isConnected ? "Live session" : "NeuroFocus"
    }
    private var subtitle: String {
        if model.isConnected { return "streaming · around-ear EEG" }
        if model.blockActive { return "focus block · no headset" }
        return "ready when you are"
    }
    private var scanning: Bool {
        model.state == .scanning || model.state == .connecting || model.state == .interrogating
    }
    private var blockClock: String { model.blockProgress.map { clockMMSS($0.elapsed) } ?? "0:00" }
    private var yesterday: Day? {
        guard let sel = days.selected, let i = days.days.firstIndex(where: { $0.key == sel.key }), i > 0
        else { return nil }
        return days.days[i - 1]
    }
    private func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
}

private func clockMMSS(_ t: TimeInterval) -> String {
    let s = max(0, Int(t)); return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Pure display (snapshot-testable)

struct SessionView: View {
    let metrics: FocusMetrics
    let withheld: Bool
    let gateReason: String?
    let sps: Int
    let title: String
    let subtitle: String
    let day: Day?
    let yesterday: Day?

    private var focusText: String { withheld ? "—" : "\(Int(metrics.focus.rounded()))" }
    private var stateLabel: String {
        if withheld { return "No signal" }
        if metrics.focus >= 75 { return "Deep Flow" }
        if metrics.focus >= 60 { return "Focused" }
        return "Drifting"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            hourChart
            if let insight { insightRow(insight) }
            HStack(alignment: .top, spacing: 12) {
                yesterdayCard
                hardwareCard
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.label(14, .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.data(10.5)).foregroundStyle(Color(hex: 0x6F6D78))
            }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(focusText)
                    .font(.system(size: 62, weight: .heavy))
                    .foregroundStyle(withheld ? Color(hex: 0x6F6D78) : .white)
                    .contentTransition(.numericText())
                if !withheld {
                    Text("%").font(.system(size: 24, weight: .bold)).foregroundStyle(Color(hex: 0x6F6D78))
                }
                statePill.padding(.leading, 6)
            }
            if withheld, let gateReason {
                Text(gateReason).font(.label(11)).foregroundStyle(Color(hex: 0xA2A0AB))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).glassPane()
    }

    private var statePill: some View {
        HStack(spacing: 6) {
            Circle().fill(Ink.amber).frame(width: 6, height: 6).shadow(color: Ink.amber, radius: 4)
            Text(stateLabel).font(.label(12, .semibold)).foregroundStyle(Ink.amber)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Ink.amber.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.amber.opacity(0.28), lineWidth: 1))
    }

    private var hourChart: some View {
        let bars = hourlyMedianFocus(day)
        let peak = bars.compactMap(\.value).max() ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AVG FOCUS BY HOUR").font(.data(10, .semibold)).tracking(1.4)
                    .foregroundStyle(Color(hex: 0x6F6D78))
                Spacer()
                if peak > 0 {
                    Text("peak · \(peakWindow(bars))").font(.data(10.5, .semibold)).foregroundStyle(Ink.amber)
                }
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(bars, id: \.hour) { b in
                    let v = b.value ?? 0
                    let isPeak = b.value != nil && peak > 0 && v >= peak - 6
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(b.value == nil
                              ? AnyShapeStyle(Color.white.opacity(0.06))
                              : (isPeak
                                 ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xE79A5C), Color(hex: 0xF7D0A6)], startPoint: .bottom, endPoint: .top))
                                 : AnyShapeStyle(Color.white.opacity(0.14))))
                        .frame(height: max(6, CGFloat(v) / 100 * 104)).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 108, alignment: .bottom)
            HStack {
                ForEach(["6 AM", "9", "12 PM", "3", "6", "9 PM"], id: \.self) { t in
                    Text(t).font(.data(10)).foregroundStyle(Color(hex: 0x6F6D78))
                    if t != "9 PM" { Spacer() }
                }
            }
            if peak == 0 {
                Text("No trusted signal recorded yet today — the chart fills in as you record.")
                    .font(.label(11)).foregroundStyle(Color(hex: 0x6F6D78))
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassPane()
    }

    private func insightRow(_ f: Finding) -> some View {
        HStack(spacing: 13) {
            Image(systemName: f.tone.icon).font(.system(size: 15)).foregroundStyle(Ink.tone(f.tone))
                .frame(width: 34, height: 34)
                .background(Ink.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(f.headline).font(.label(12.5)).foregroundStyle(Color(hex: 0xA2A0AB))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Ink.amber.opacity(0.20), lineWidth: 1))
    }

    private var insight: Finding? { day?.findings.first }

    private var yesterdayCard: some View {
        let s = yesterday.map(summarize)
        return VStack(alignment: .leading, spacing: 0) {
            Text("YESTERDAY").font(.data(9.5, .semibold)).tracking(1.2).foregroundStyle(Color(hex: 0x6F6D78))
            Text(s?.deepFlow ?? "—").font(.system(size: 26, weight: .heavy)).foregroundStyle(.white).padding(.top, 10)
            Text("deep flow").font(.label(11)).foregroundStyle(Color(hex: 0xA2A0AB))
            VStack(spacing: 8) {
                statRow("Longest block", s?.longestBlock ?? "—")
                statRow("Context switches", s.map { "\($0.contextSwitches)" } ?? "—")
                statRow("Best block", s?.bestBlock ?? "—")
            }
            .padding(.top, 13)
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading).glassPane()
    }

    private var hardwareCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SENSOR").font(.data(9.5, .semibold)).tracking(1.2).foregroundStyle(Color(hex: 0x6F6D78))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sps > 0 ? "\(sps)" : "—").font(.system(size: 26, weight: .heavy)).foregroundStyle(.white)
                Text("SPS").font(.label(11)).foregroundStyle(Color(hex: 0xA2A0AB))
            }
            .padding(.top, 10)
            Text("single around-ear dry channel").font(.label(11)).foregroundStyle(Color(hex: 0xA2A0AB))
            VStack(spacing: 8) {
                statRow("Score", "Pope β/(α+θ)")
                statRow("RMS", String(format: "%.2f µV", metrics.rmsUv))
                statRow("Contact", metrics.signalOk ? "OK" : "no contact")
            }
            .padding(.top, 13)
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading).glassPane()
    }

    private func statRow(_ l: String, _ v: String) -> some View {
        HStack {
            Text(l).font(.label(11.5)).foregroundStyle(Color(hex: 0xA2A0AB))
            Spacer()
            Text(v).font(.label(11.5)).foregroundStyle(.white).lineLimit(1)
        }
    }
}

// MARK: - Real-data helpers

struct HourFocus: Identifiable { let hour: Int; let value: Double?; var id: Int { hour } }

func hourlyMedianFocus(_ day: Day?) -> [HourFocus] {
    var buckets: [[Double]] = Array(repeating: [], count: 24)
    if let day {
        let cal = Calendar.current
        for s in day.sessions {
            for e in s.epochs where e.trustworthy {
                guard let f = e.focus else { continue }
                buckets[cal.component(.hour, from: s.date(at: e.t))].append(f)
            }
        }
    }
    return (6...21).map { h in
        let vals = buckets[h].sorted()
        return HourFocus(hour: h, value: vals.isEmpty ? nil : vals[vals.count / 2])
    }
}

func peakWindow(_ bars: [HourFocus]) -> String {
    guard let peak = bars.compactMap(\.value).max(),
          let first = bars.first(where: { ($0.value ?? 0) >= peak - 6 }),
          let last = bars.last(where: { ($0.value ?? 0) >= peak - 6 }) else { return "—" }
    func label(_ h: Int) -> String { h == 12 ? "12 PM" : (h > 12 ? "\(h - 12) PM" : "\(h) AM") }
    return "\(label(first.hour))–\(label(last.hour))"
}

struct DaySummaryVM { let deepFlow: String; let longestBlock: String; let contextSwitches: Int; let bestBlock: String }

func summarize(_ day: Day) -> DaySummaryVM {
    let flow = Int(day.totalFocusedSec)
    let longest = Int(day.segments.map(\.longestFlowSec).max() ?? 0)
    let best = day.segments.filter(\.sayable).max { ($0.medianFocus ?? 0) < ($1.medianFocus ?? 0) }
    return DaySummaryVM(
        deepFlow: flow >= 3600 ? "\(flow / 3600)h \((flow % 3600) / 60)m" : "\(flow / 60)m",
        longestBlock: "\(longest / 60) min",
        contextSwitches: day.segments.count,
        bestBlock: best.map { "\(clock($0.span.start)) · \($0.span.label)" } ?? "—")
}

// MARK: - Glass + hex helpers

extension View {
    /// The frosted content pane used across the one-page window.
    func glassPane() -> some View {
        self
            .background(
                LinearGradient(colors: [Color.white.opacity(0.05), Color.white.opacity(0.012)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
