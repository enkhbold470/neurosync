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

    /// Boards seen while scanning, strongest first. The connect screen turns this into a picker so
    /// you choose YOUR board when several are powered on. Empty unless actively scanning.
    private(set) var discoveredBoards: [DiscoveredBoard] = []

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
    // A block is N minutes the user declared they mean to concentrate in. THE BLOCK IS
    // HARDWARE-OPTIONAL — see Core/FocusBlock.swift. It runs in two tiers each second:
    //
    //   Tier 1 (always): the measured frontmost-app context feeds `appDrift` and `behaviorTally`.
    //     This is behaviour, not a brain number — it never touches Manifesto II.
    //   Tier 2 (only while a board streams): the gated, smoothed brain state feeds `drift`, and the
    //     epoch is accumulated so the brain recap and any saved SessionRecord come from one `[Epoch]`.
    //
    // Starting a block is the honest, user-supplied source of `effortful = true`; it is NEVER inferred
    // from the brain state. Losing the headset mid-block does NOT end the block — it just drops Tier 2
    // and the block carries on headset-free. A single unified debounce spaces the two sources apart so
    // you never get a double cue.

    private(set) var block: ActiveBlock?
    /// The last completed block's summary, for the recap surface. Cleared when a new block starts.
    private(set) var lastRecap: BlockRecap?
    /// True for a few seconds after a drift nudge fires — a glanceable menu-bar state change.
    private(set) var driftAlert = false
    /// What the last drift nudge said, adapted to its source (app-away vs brain-drift).
    private(set) var driftAlertMessage = ""

    /// Which tier tripped the nudge — drives the copy (measured "away" vs brain "drifting").
    private enum DriftSource { case app, brain }

    @ObservationIgnored private let blockConfig = FocusBlockConfig()
    @ObservationIgnored private var drift = DriftIntervention()
    @ObservationIgnored private var appDrift = AppDriftDetector()
    @ObservationIgnored private var behaviorTally = BehaviorTally()
    @ObservationIgnored private var blockBuilder = EpochBuilder()
    @ObservationIgnored private var blockEpochs: [Epoch] = []
    @ObservationIgnored private var blockTick: Timer?
    @ObservationIgnored private var blockLastSecond = -1
    /// Unified debounce clock across both drift sources.
    @ObservationIgnored private var lastBlockNudgeAt = Date.distantPast
    @ObservationIgnored private var driftAlertClear: Timer?

    var blockActive: Bool { block != nil }

    init() {
        link.onState = { [weak self] s in
            Task { @MainActor in self?.handle(state: s) }
        }
        link.onSnapshot = { [weak self] s in
            Task { @MainActor in self?.ingest(s) }
        }
        link.onDiscover = { [weak self] boards in
            Task { @MainActor in self?.discoveredBoards = boards }
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
            // The board is gone, but a running block is NOT — it falls back to the headset-free tier
            // and keeps timing + watching app context. Only the user (or Quit) ends a block.
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

    /// Start a block of `minutes` minutes, with an optional one-line intention. No headset required —
    /// this turns on BOTH drift tiers (app-context always; brain only while a board streams). Starting
    /// a block is what declares `effortful = true` for any brain epochs — user-supplied, never
    /// inferred from the signal. The block anchors to the effortful app you start in, for the nudge.
    func startBlock(minutes: Int? = nil, intention: String? = nil) {
        endBlock()   // never stack two blocks

        let n = minutes ?? blockConfig.plannedMinutes
        let start = Date()
        let app = frontmostAppSample()
        let anchor = app.kind.isEffortful ? app.label : nil
        let trimmed = intention?.trimmingCharacters(in: .whitespacesAndNewlines)

        block = ActiveBlock(
            startedAt: start,
            plannedMinutes: n,
            intention: (trimmed?.isEmpty == false) ? trimmed : nil,
            anchorLabel: anchor
        )
        lastRecap = nil
        driftAlert = false
        driftAlertMessage = ""
        lastBlockNudgeAt = .distantPast
        drift = DriftIntervention(driftDwellSec: blockConfig.driftDwellSec,
                                  debounceSec: blockConfig.debounceSec)
        appDrift = AppDriftDetector(awayDwellSec: blockConfig.appDriftDwellSec,
                                    debounceSec: blockConfig.debounceSec)
        behaviorTally = BehaviorTally()
        blockBuilder = EpochBuilder()
        blockEpochs = []
        blockLastSecond = -1

        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.blockStep() }
        }
        RunLoop.main.add(t, forMode: .common)
        blockTick = t
    }

    /// One tick per wall-clock second. Tier 1 (app context) always runs; Tier 2 (brain epoch + EEG
    /// drift) runs only while a board streams. Either source may trip a nudge, but a single unified
    /// debounce spaces them, so a slump — brain, app, or both — is one cue, never a storm.
    private func blockStep() {
        guard var b = block else { return }
        let sec = Int(Date().timeIntervalSince(b.startedAt))
        guard sec > blockLastSecond else { return }
        let dt = Double(sec - blockLastSecond)          // usually 1; robust if a tick is skipped
        blockLastSecond = sec

        // Tier 1 — measured app context. A fact about which app was frontmost, nothing more.
        let app = frontmostAppSample()
        let ctx = workContext(for: app.kind)
        behaviorTally.add(kind: app.kind, label: app.label, bundleId: app.bundleId, seconds: Int(dt))
        b.onTaskSeconds = behaviorTally.onTaskSeconds
        b.awaySeconds = behaviorTally.awaySeconds
        b.currentLabel = app.label
        b.currentContext = ctx
        let appFired = appDriftStep(&appDrift, blockActive: true, context: ctx, dt: dt)

        // Tier 2 — brain, ONLY while a board is actually streaming. No board → no brain epoch this
        // second → the brain recap stays nil and no focus number can ever be rendered.
        var brainFired = false
        if isConnected {
            let epoch = blockBuilder.close(second: Double(sec), metrics: snap.metrics, effortful: true)
            blockEpochs.append(epoch)
            // A closed gate is `.withheld` here — never `.daydream` — so nothing fires behind a gate.
            brainFired = driftStep(&drift, blockActive: true, state: epoch.state, dt: dt)
        }

        // Unified debounce across BOTH tiers: at most one nudge per window, never a double cue.
        if appFired || brainFired {
            let now = Date()
            if now.timeIntervalSince(lastBlockNudgeAt) >= blockConfig.debounceSec {
                lastBlockNudgeAt = now
                b.driftCatches += 1
                fireDriftNudge(source: brainFired ? .brain : .app, anchor: b.anchorLabel)
            }
        }

        block = b
    }

    /// The intervention itself: a subtle sound, a menu-bar state change, and a haptic hook. The pure
    /// detectors already decided this should fire; this only performs it, with copy adapted to which
    /// tier tripped it.
    private func fireDriftNudge(source: DriftSource, anchor: String?) {
        // A subtle, non-alarming cue — a soft named system sound, not the alert beep.
        (NSSound(named: "Tink") ?? NSSound(named: "Pop"))?.play()

        // Haptic hook for later. On a trackpad this is felt; elsewhere it is a no-op. Left here as the
        // seam a future richer haptic pattern plugs into.
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)

        // The menu-bar state change: a glanceable, briefly-held message adapted to the source. The
        // app-context copy is a neutral check-in, never an accusation — we can't see your tab.
        switch source {
        case .brain:
            driftAlertMessage = "Drifting — want to reset?"
        case .app:
            driftAlertMessage = anchor.map { "Away from \($0) — still on it?" }
                ?? "Away from your work app — still on it?"
        }
        driftAlert = true
        driftAlertClear?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            MainActor.assumeIsolated { self.driftAlert = false }
        }
        RunLoop.main.add(t, forMode: .common)
        driftAlertClear = t
    }

    /// End the block: build the two-part recap (behavioural always, brain only if a board was on),
    /// persist any brain epochs as a SessionRecord, and stop the loop. Safe to call with no block.
    func endBlock() {
        blockTick?.invalidate()
        blockTick = nil
        driftAlertClear?.invalidate()
        driftAlertClear = nil
        driftAlert = false

        guard let b = block else { return }

        let behavior = behaviorTally.recap(slips: appDrift.nudges)
        lastRecap = makeRecap(behavior: behavior, epochs: blockEpochs, driftCatches: b.driftCatches)
        persistBlock(b, epochs: blockEpochs)

        block = nil
        drift.reset()
        appDrift.reset()
        behaviorTally = BehaviorTally()
        blockEpochs = []
    }

    /// Save the block's BRAIN epochs as a SessionRecord through the existing Store — same schema, same
    /// gates. A withheld epoch keeps its null score. A headset-free block has no brain epochs, so it
    /// is not persisted here (its live recap still stands); persisting behavioural-only blocks into
    /// the DAY timeline is deliberately deferred — see the spec. Requires a granted folder.
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
    /// Connect to a board the user picked from the scan list.
    func connect(to id: UUID) { link.connect(to: id) }
    func disconnect() { link.disconnect() }
    func requestDiag() { link.requestDiag() }

    func recalibrate() {
        focusHistory.removeAll()
        link.recalibrate()
    }

    /// The optional "Optimize" — capture a personal baseline instead of the generic default.
    func optimize() {
        focusHistory.removeAll()
        link.optimize()
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
        // A running block speaks first — it works with or without a board. `driftAlert` only ever
        // fires inside a block, so it implies one is active.
        if blockActive {
            return driftAlert ? "DRIFTING" : "FOCUS BLOCK"
        }
        switch state {
        case .idle: return "NO DEVICE"
        case .bluetoothOff: return "BT OFF"
        case .unauthorized: return "BT DENIED"
        case .scanning: return "SCANNING"
        case .connecting: return "CONNECTING"
        case .interrogating: return "READING BOARD"
        case .failed: return "FAULT"
        case .streaming:
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
    var blockIntention: String? { block?.intention }
    var blockAnchorLabel: String? { block?.anchorLabel }
    var blockOnTaskSeconds: Int { block?.onTaskSeconds ?? 0 }
    var blockAwaySeconds: Int { block?.awaySeconds ?? 0 }
    /// The frontmost app right now and whether it counts as on-task — for the live block surface.
    var blockCurrentLabel: String? { block?.currentLabel }
    var blockCurrentContext: WorkContext { block?.currentContext ?? .neutral }

    // MARK: Frontmost-app sampling (measured context — bundle id only, no titles/URLs/keystrokes)

    /// The frontmost app this instant, classified. When NeuroSync itself is frontmost (you're looking
    /// at the block window) the bundle is unrecognised → `.neutral`: it neither nags nor counts as
    /// work, which is exactly right. Nil frontmost → unknown/neutral.
    private func frontmostAppSample() -> (kind: ActivityKind, label: String, bundleId: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return (.unknown, "Unknown", nil)
        }
        let bundle = app.bundleIdentifier
        let kind = bundle.map(activityForBundle) ?? .unknown
        return (kind, app.localizedName ?? bundle ?? "Unknown", bundle)
    }
}
