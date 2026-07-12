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
