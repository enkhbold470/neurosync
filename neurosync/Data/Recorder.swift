//
//  Recorder.swift
//  neurosync
//
//  Raw ADC counts → 1 Hz epochs. The ONLY path from signal to disk.
//
//  A live board and a synthetic waveform both come through here, through the same FocusEngine, the
//  same gates and the same state machine. That is what makes the synthetic sessions honest enough to
//  ship at all: their *waveforms* are generated, but not one number in them is typed in — every
//  focus, calm and clench value was computed by the DSP a real brain goes through. If the generator
//  produces a signal that the gates refuse, the gates refuse it, and the JSON records the refusal.
//
//  `nonisolated`: this runs on VertexLink's serial queue, never on the main actor.
//

import Foundation

/// Metrics → one epoch per second, with the state hysteresis in tow.
///
/// Extracted so that BOTH paths use it and cannot drift apart:
///
///   * `SessionRecorder` owns its own `FocusEngine` and drives this from raw counts. That is the
///     synthetic path, and the offline path.
///   * `VertexModel` drives this from the LIVE link's metrics — the link already runs a
///     `FocusEngine`, and standing up a second one to record from would double the DSP cost and,
///     worse, allow the recorded numbers to diverge from the ones on screen.
///
/// One implementation, so the JSON on disk always agrees with the window it was recorded from.
nonisolated struct EpochBuilder {
    private var smoother = StateSmoother()

    /// Close a second. `t` is seconds since the session start.
    mutating func close(second t: Double, metrics m: FocusMetrics, effortful: Bool) -> Epoch {
        let instant = resolveState(m, effortful: effortful)
        let state = smoother.step(instant, dt: 1.0)

        var bands: [String: Double] = [:]
        for (b, v) in m.bands { bands[b.rawValue] = v }

        // The scores are nil when a gate is closed. NOT zero — nil. A reader who sees `focus: 0`
        // thinks the brain was idle; a reader who sees `focus: null` knows the instrument declined
        // to answer, which is the truth.
        let trusted = m.trustworthy

        return Epoch(
            t: t,
            focus: trusted ? m.focus : nil,
            calm: trusted ? m.calm : nil,
            clench: trusted ? m.clench : nil,
            engagement: m.engagement,
            bands: bands,
            alphaPeak: m.alphaPeak,
            rmsUv: m.rmsUv,
            signalOk: m.signalOk,
            fsOk: m.fsOk,
            calibrating: m.calibrating,
            state: state
        )
    }
}

nonisolated final class SessionRecorder {
    let fs: Double
    private let engine: FocusEngine
    private var builder = EpochBuilder()

    private(set) var epochs: [Epoch] = []

    private var samplesInSecond = 0
    private var secondIndex = 0

    /// Was this second inside a block you meant to concentrate in? Supplied by the caller, because
    /// the EEG cannot know — see `resolveState`. Defaults to "no", which is the conservative answer:
    /// with no context, alpha-up disengagement is scored as rest, not as a failure to concentrate.
    private let effortfulAt: (Double) -> Bool

    init(fs: Double, options: FocusOptions = FocusOptions(), scale: ScaleSettings = .v4,
         effortfulAt: @escaping (Double) -> Bool = { _ in false }) {
        self.fs = fs
        self.engine = FocusEngine(fs: fs, options: options, scale: scale)
        self.effortfulAt = effortfulAt
    }

    var metrics: FocusMetrics { engine.metrics }
    var baseline: Double? { engine.metrics.baseline }
    var clenchBaseline: Double? { engine.metrics.clenchBaseline }

    /// One raw ADC count. Closes an epoch every `fs` samples.
    func push(counts: Int32) {
        engine.push(counts: counts)
        samplesInSecond += 1
        guard samplesInSecond >= Int(fs.rounded()) else { return }
        samplesInSecond = 0
        closeSecond()
    }

    private func closeSecond() {
        let t = Double(secondIndex)
        secondIndex += 1
        epochs.append(builder.close(second: t, metrics: engine.metrics, effortful: effortfulAt(t)))
    }

    /// Seal the recording into a record. `activities` and `markers` are context, gathered elsewhere.
    func finish(
        startedAt: Date,
        device: DeviceInfo,
        activities: [ActivitySpan] = [],
        markers: [Marker] = [],
        synthetic: Bool = false,
        syntheticNote: String? = nil
    ) -> SessionRecord {
        let m = engine.metrics
        return SessionRecord(
            synthetic: synthetic,
            syntheticNote: syntheticNote,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(epochs.count)),
            device: device,
            baseline: m.baseline.map {
                BaselineInfo(
                    engagement: $0,
                    clench: m.clenchBaseline,
                    // The baseline freezes 20 s of good signal in, so that is where it was frozen.
                    frozenAt: startedAt.addingTimeInterval(20),
                    reused: false
                )
            },
            epochs: epochs,
            activities: activities,
            markers: markers
        )
    }
}
