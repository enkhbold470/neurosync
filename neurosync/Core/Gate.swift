//
//  Gate.swift
//  neurosync
//
//  Which refusal, if any, is currently blocking a trustworthy score — and what the ambient
//  (menu bar) readout is allowed to say.
//
//  This is deliberately pure and nonisolated rather than living inside the view model, because
//  it is the single most safety-critical decision in the app and it must be testable without a
//  radio, a window, or a main actor.
//
//  The menu bar is the most dangerous surface here. A number in the window sits beside a scope,
//  a spectrum, a calibration state and a paragraph of caveats. A number in the menu bar sits
//  beside the clock. It is glanced at and believed. So it gets a dash unless every gate is open.
//

import Foundation

struct Gate: Equatable, Sendable {
    enum Kind: Sendable { case rate, signal, calibrating, warmup }
    var title: String
    var detail: String
    var kind: Kind
}

/// The one gate currently blocking a score, or nil if the number can be trusted.
///
/// Order matters: an infeasible sample rate makes the score meaningless no matter how clean the
/// signal is, so it is checked first.
nonisolated func blockingGate(connected: Bool, metrics m: FocusMetrics) -> Gate? {
    guard connected else { return nil }

    if !m.fsOk {
        return Gate(
            title: "SCORE WITHHELD — SAMPLE RATE",
            detail: m.fsReason ?? "The Pope index is not defensible at this sample rate.",
            kind: .rate
        )
    }
    if m.warmingUp {
        return Gate(
            title: "FILLING WINDOW",
            detail: "Collecting the first analysis window.",
            kind: .warmup
        )
    }
    if !m.signalOk {
        return Gate(
            title: "NO BIOSIGNAL",
            detail: String(
                format: "%.2f µV RMS — below the 1.5 µV noise floor. The electrode is not making skin contact.",
                m.rmsUv),
            kind: .signal
        )
    }
    if m.calibrating {
        return Gate(
            title: "CALIBRATING BASELINE",
            detail: String(
                format: "%.0f s of good signal remaining. 50 will mean YOUR baseline.",
                m.calibrationLeftSec),
            kind: .calibrating
        )
    }
    return nil
}

/// What the menu bar is permitted to display.
///
/// A dash whenever the score cannot be trusted — never a stale value, never an ungated one.
/// The window can afford to show a frozen number next to the reason it is frozen; the menu bar
/// cannot, because there is nowhere to put the reason.
nonisolated func ambientValue(connected: Bool, metrics: FocusMetrics) -> String {
    guard connected, blockingGate(connected: connected, metrics: metrics) == nil else {
        return "—"
    }
    return "\(Int(metrics.focus.rounded()))"
}
