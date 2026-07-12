//
//  VertexModel.swift
//  neurosync
//

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

    init() {
        link.onState = { [weak self] s in
            Task { @MainActor in self?.state = s }
        }
        link.onSnapshot = { [weak self] s in
            Task { @MainActor in self?.ingest(s) }
        }
    }

    private func ingest(_ s: VertexSnapshot) {
        snap = s

        // Only trace what is real. A frozen or gated score is not a data point.
        guard s.metrics.signalOk, !s.metrics.warmingUp else { return }

        alphaHistory.append(s.metrics.bands[.alpha] ?? 0)
        if alphaHistory.count > Self.historyCap { alphaHistory.removeFirst() }

        if !s.metrics.calibrating && s.metrics.fsOk {
            focusHistory.append(s.metrics.focus)
            if focusHistory.count > Self.historyCap { focusHistory.removeFirst() }
        }
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

    /// The single gate currently blocking a trustworthy score, if any. Order is deliberate:
    /// an infeasible sample rate makes the score meaningless no matter how good the signal is.
    var blockingGate: Gate? {
        guard isConnected else { return nil }
        let m = metrics
        if !m.fsOk {
            return Gate(
                title: "SCORE WITHHELD — SAMPLE RATE",
                detail: m.fsReason ?? "The Pope index is not defensible at this sample rate.",
                kind: .rate
            )
        }
        if m.warmingUp {
            return Gate(title: "FILLING WINDOW", detail: "Collecting the first analysis window.", kind: .warmup)
        }
        if !m.signalOk {
            return Gate(
                title: "NO BIOSIGNAL",
                detail: String(format: "%.2f µV RMS — below the 1.5 µV noise floor. The electrode is not making skin contact.", m.rmsUv),
                kind: .signal
            )
        }
        if m.calibrating {
            return Gate(
                title: "CALIBRATING BASELINE",
                detail: String(format: "%.0f s of good signal remaining. 50 will mean YOUR baseline.", m.calibrationLeftSec),
                kind: .calibrating
            )
        }
        return nil
    }

    struct Gate: Equatable {
        enum Kind { case rate, signal, calibrating, warmup }
        var title: String
        var detail: String
        var kind: Kind
    }
}
