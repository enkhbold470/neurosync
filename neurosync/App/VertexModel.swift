//
//  VertexModel.swift
//  neurosync
//

import AppKit
import Foundation
import Observation

/// Main-actor view state. Owns the link; holds no signal processing of its own.
@Observable
final class VertexModel {
    private(set) var state: LinkState = .idle
    private(set) var snap = VertexSnapshot()

    /// Rolling traces for the session views, ~30 Hz, 30 s deep.
    private(set) var alphaHistory: [Double] = []
    private(set) var focusHistory: [Double] = []
    private static let historyCap = 900

    private let link = VertexLink()

    // MARK: Recording
    //
    // A live session records itself to disk as it goes. The epochs are built from the LINK's engine
    // — the same one feeding the window — so the JSON and the screen can never disagree.
    //
    // `store` is set by the App. When it is nil (no folder granted), nothing is recorded and nothing
    // is lost: the instrument still works, it just does not keep a diary.

    var store: Store?
    private let watcher = ActivityWatcher()

    private var recStart: Date?
    private var recBuilder = EpochBuilder()
    private var recEpochs: [Epoch] = []
    private var recMarkers: [Marker] = []
    private var recTick: Timer?
    private var lastSecond = -1

    /// Fires when a session is sealed, so the Day view can reload.
    var onSessionWritten: (() -> Void)?

    var isRecording: Bool { recStart != nil }

    // MARK: Nudge
    //
    // The "you're crashing out" signal. Driven ONLY by trustworthy live focus (see `ingest`), shown
    // on the Dock. When there is no trustworthy signal it clears — a frozen or withheld score must
    // never strand a stale "!" on the Dock.

    private(set) var nudge: FocusNudge.Level = .none
    @ObservationIgnored private var nudgeEngine = FocusNudge()
    @ObservationIgnored private var lastNudgeAt: Date?
    @ObservationIgnored private var lostFor: Double = 0

    init() {
        link.onState = { [weak self] s in
            Task { @MainActor in self?.handle(state: s) }
        }
        link.onSnapshot = { [weak self] s in
            Task { @MainActor in self?.ingest(s) }
        }
    }

    private func handle(state s: LinkState) {
        let was = state
        state = s

        switch s {
        case .streaming where !isRecording:
            beginRecording()
        case .idle, .failed, .bluetoothOff, .unauthorized:
            if was == .streaming || isRecording { endRecording() }
            clearNudge()
        default:
            break
        }
    }

    private func ingest(_ s: VertexSnapshot) {
        snap = s

        updateNudge(s.metrics)

        // Only trace what is real. A frozen or gated score is not a data point.
        guard s.metrics.signalOk, !s.metrics.warmingUp else { return }

        alphaHistory.append(s.metrics.bands[.alpha] ?? 0)
        if alphaHistory.count > Self.historyCap { alphaHistory.removeFirst() }

        if !s.metrics.calibrating && s.metrics.fsOk {
            focusHistory.append(s.metrics.focus)
            if focusHistory.count > Self.historyCap { focusHistory.removeFirst() }
        }
    }

    // MARK: Nudge driving

    private func updateNudge(_ m: FocusMetrics) {
        let now = Date()
        let dt = lastNudgeAt.map { min(5, max(0, now.timeIntervalSince($0))) } ?? 0
        lastNudgeAt = now

        if m.trustworthy {
            lostFor = 0
            let newLevel = nudgeEngine.sample(focus: m.focus, dt: dt)
            setNudge(newLevel)
        } else {
            // No trustworthy score. Hold briefly (a blink is not a recovery), then clear — a
            // withheld or frozen score must not keep a stale nudge on the Dock.
            lostFor += dt
            if lostFor > 10 { clearNudge() }
        }
    }

    private func setNudge(_ level: FocusNudge.Level) {
        guard level != nudge else { return }
        let escalated = level > nudge
        nudge = level
        applyDock(level, bounce: escalated)
    }

    private func clearNudge() {
        nudgeEngine.reset()
        lostFor = 0
        setNudge(.none)
    }

    /// The Dock badge is the whole ask: a glanceable "!" when you're crashing out. Escalating to a
    /// nudge also bounces the icon once, so it catches your eye even when NeuroSync is in the back.
    private func applyDock(_ level: FocusNudge.Level, bounce: Bool) {
        NSApp.dockTile.badgeLabel = level.badge
        NSApp.dockTile.display()
        if bounce, level != .none {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: Recording lifecycle

    private func beginRecording() {
        guard store != nil else { return }
        recStart = Date()
        recEpochs = []
        recMarkers = []
        recBuilder = EpochBuilder()
        lastSecond = -1
        watcher.begin()

        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        recTick = t
    }

    /// One epoch per wall-clock second, from whatever the link's engine last computed.
    private func tick() {
        guard let recStart else { return }
        let sec = Int(Date().timeIntervalSince(recStart))
        guard sec > lastSecond else { return }
        lastSecond = sec

        // Was this second inside a block you meant to concentrate in? The EEG cannot know — see
        // `resolveState`. Only the calendar and the frontmost app can, so they are asked.
        let now = recStart.addingTimeInterval(Double(sec))
        let effortful = watcher.spans(until: now.addingTimeInterval(1))
            .contains { $0.kind.isEffortful && $0.contains(now) }

        recEpochs.append(recBuilder.close(
            second: Double(sec), metrics: snap.metrics, effortful: effortful))
    }

    private func endRecording() {
        recTick?.invalidate()
        recTick = nil
        watcher.end()

        defer {
            recStart = nil
            recEpochs = []
            recMarkers = []
        }

        guard let store, let recStart, recEpochs.count >= 30 else { return }

        let rec = SessionRecord(
            synthetic: false,
            syntheticNote: nil,
            startedAt: recStart,
            endedAt: recStart.addingTimeInterval(Double(recEpochs.count)),
            device: DeviceInfo(
                name: snap.info?.name ?? Vertex.deviceName,
                sps: snap.info?.sps ?? Int(snap.fs),
                firmware: snap.info?.fw
            ),
            baseline: snap.metrics.baseline.map {
                BaselineInfo(engagement: $0, clench: snap.metrics.clenchBaseline,
                             frozenAt: recStart.addingTimeInterval(20), reused: false)
            },
            epochs: recEpochs,
            activities: watcher.spans(),
            markers: recMarkers
        )

        try? store.write(rec)
        onSessionWritten?()
    }

    /// A self-reported marker during a live session. Kept in the record AND appended to
    /// markers.jsonl, so it survives even if the session never seals.
    func mark(_ kind: MarkerKind, note: String? = nil) {
        let m = Marker(kind: kind, at: Date(), note: note)
        if isRecording { recMarkers.append(m) }
        try? store?.append(m)
    }

    // MARK: Intents

    func connect() { link.connect() }
    func disconnect() { link.disconnect() }
    func requestDiag() { link.requestDiag() }

    func recalibrate() {
        focusHistory.removeAll()
        link.recalibrate()
    }

    func setRate(index: Int) {
        alphaHistory.removeAll()
        focusHistory.removeAll()
        link.setRate(index: index)
    }

    // MARK: Derived

    var isConnected: Bool {
        switch state {
        case .streaming, .interrogating: return true
        default: return false
        }
    }

    var metrics: FocusMetrics { snap.metrics }

    /// The single gate currently blocking a trustworthy score, if any.
    /// The decision lives in `Core/Gate.swift` — pure, nonisolated, and tested without a radio.
    var blockingGate: Gate? {
        neurosync.blockingGate(connected: isConnected, metrics: metrics)
    }

    // MARK: Ambient readout

    /// What the menu bar shows. A dash whenever a score cannot be trusted.
    var menuBarValue: String {
        ambientValue(connected: isConnected, metrics: metrics)
    }

    var menuBarState: String {
        switch state {
        case .idle: return "NO DEVICE"
        case .bluetoothOff: return "BT OFF"
        case .unauthorized: return "BT DENIED"
        case .scanning: return "SCANNING"
        case .connecting: return "CONNECTING"
        case .interrogating: return "READING BOARD"
        case .failed: return "FAULT"
        case .streaming: return blockingGate == nil ? "LIVE" : "WITHHELD"
        }
    }
}
