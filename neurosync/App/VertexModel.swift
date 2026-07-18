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

    // MARK: Focus block
    //
    // A block is N minutes the user declared they mean to concentrate in. It is the honest source of
    // the `effortful` context `resolveState` requires — the calendar/app watcher is the other one —
    // and it is NEVER inferred from the brain state. While a block runs, its own per-second loop
    // drives the drift intervention off the SAME gated, smoothed state stream the recorder writes to
    // disk, and accumulates the block's epochs so the recap and the saved SessionRecord are built
    // from one `[Epoch]` and can't disagree. With no board, the loop produces `.withheld` epochs and
    // nothing fires.

    private(set) var block: ActiveBlock?
    /// The last completed block's summary, for the recap surface. Cleared when a new block starts.
    private(set) var lastRecap: BlockRecap?
    /// True for a few seconds after a drift nudge fires — a glanceable menu-bar state change.
    private(set) var driftAlert = false

    @ObservationIgnored private let blockConfig = FocusBlockConfig()
    @ObservationIgnored private var drift = DriftIntervention()
    @ObservationIgnored private var blockBuilder = EpochBuilder()
    @ObservationIgnored private var blockEpochs: [Epoch] = []
    @ObservationIgnored private var blockTick: Timer?
    @ObservationIgnored private var blockLastSecond = -1
    @ObservationIgnored private var driftAlertClear: Timer?

    var blockActive: Bool { block != nil }

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
            if blockActive { endBlock() }   // the board is gone — seal the block honestly and stop
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

    // MARK: Focus block lifecycle

    /// Start a block of `minutes` minutes. This is the ONLY thing that turns on the drift
    /// intervention. Starting a block is also what declares `effortful = true` for the block's
    /// epochs — the honest, user-supplied context `resolveState` needs.
    func startBlock(minutes: Int? = nil) {
        endBlock()   // never stack two blocks

        let n = minutes ?? blockConfig.plannedMinutes
        let start = Date()
        block = ActiveBlock(startedAt: start, plannedMinutes: n)
        lastRecap = nil
        driftAlert = false
        drift = DriftIntervention(driftDwellSec: blockConfig.driftDwellSec,
                                  debounceSec: blockConfig.debounceSec)
        blockBuilder = EpochBuilder()
        blockEpochs = []
        blockLastSecond = -1

        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.blockStep() }
        }
        RunLoop.main.add(t, forMode: .common)
        blockTick = t
    }

    /// One block epoch per wall-clock second, built from the live link's last metrics through the
    /// shared `EpochBuilder` — the same DSP path the recorder uses. `effortful: true` is the block's
    /// declaration, not an inference from the signal.
    private func blockStep() {
        guard let b = block else { return }
        let sec = Int(Date().timeIntervalSince(b.startedAt))
        guard sec > blockLastSecond else { return }
        blockLastSecond = sec

        let epoch = blockBuilder.close(second: Double(sec), metrics: snap.metrics, effortful: true)
        blockEpochs.append(epoch)

        // Drift detection off the gated, smoothed state, through the shared `driftStep` gate. A
        // closed gate is `.withheld` here — never `.daydream` — so nothing fires behind a gate; and
        // `driftStep` refuses to advance the detector at all unless a block is active.
        if driftStep(&drift, blockActive: true, state: epoch.state, dt: 1.0) {
            block?.driftCatches += 1
            fireDriftNudge()
        }
    }

    /// The intervention itself: a subtle sound, a menu-bar state change, and a haptic hook. The pure
    /// `DriftIntervention` already decided this should fire and counted it; this only performs it.
    private func fireDriftNudge() {
        // A subtle, non-alarming cue — a soft named system sound, not the alert beep.
        (NSSound(named: "Tink") ?? NSSound(named: "Pop"))?.play()

        // Haptic hook for later. On a trackpad this is felt; elsewhere it is a no-op. Left here as the
        // seam a future richer haptic pattern plugs into.
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)

        // The menu-bar state change: DRIFTING, held briefly so it is glanceable, then cleared.
        driftAlert = true
        driftAlertClear?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            MainActor.assumeIsolated { self.driftAlert = false }
        }
        RunLoop.main.add(t, forMode: .common)
        driftAlertClear = t
    }

    /// End the block: compute the recap from the block's own epochs, persist it as a SessionRecord,
    /// and stop the loop. Safe to call when no block is active.
    func endBlock() {
        blockTick?.invalidate()
        blockTick = nil
        driftAlertClear?.invalidate()
        driftAlertClear = nil
        driftAlert = false

        guard let b = block else { return }

        lastRecap = recap(epochs: blockEpochs, driftCatches: b.driftCatches)
        persistBlock(b, epochs: blockEpochs)

        block = nil
        drift.reset()
        blockEpochs = []
    }

    /// Save the block as a SessionRecord through the existing Store — same schema, same gates. A
    /// withheld epoch keeps its null score. Requires a granted folder and a real block; otherwise the
    /// live recap still stands, nothing is lost.
    private func persistBlock(_ b: ActiveBlock, epochs: [Epoch]) {
        guard let store, epochs.count >= 30 else { return }
        let rec = SessionRecord(
            synthetic: false,
            syntheticNote: nil,
            startedAt: b.startedAt,
            endedAt: b.startedAt.addingTimeInterval(Double(epochs.count)),
            device: DeviceInfo(
                name: snap.info?.name ?? Vertex.deviceName,
                sps: snap.info?.sps ?? Int(snap.fs),
                firmware: snap.info?.fw
            ),
            baseline: snap.metrics.baseline.map {
                BaselineInfo(engagement: $0, clench: snap.metrics.clenchBaseline,
                             frozenAt: b.startedAt.addingTimeInterval(20), reused: false)
            },
            epochs: epochs,
            activities: [],
            markers: []
        )
        try? store.write(rec)
        onSessionWritten?()
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
        case .streaming:
            if driftAlert { return "DRIFTING" }
            return blockingGate == nil ? "LIVE" : "WITHHELD"
        }
    }

    // MARK: Block-derived readouts (live model only — never persisted or synthetic data)

    /// The block's elapsed / planned, for the menu bar. Nil when no block is running.
    var blockProgress: (elapsed: TimeInterval, planned: TimeInterval)? {
        guard let block else { return nil }
        return (block.elapsed(at: Date()), Double(block.plannedMinutes) * 60)
    }

    var blockDriftCatches: Int { block?.driftCatches ?? 0 }
}
