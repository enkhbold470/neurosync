//
//  SessionRecord.swift
//  neurosync
//
//  What lands on disk, in ~/Desktop/neurosync-local/. Plain JSON, human-readable, no database.
//
//  Two rules govern this schema, and both are about not lying to a reader who opens the file cold
//  in six months:
//
//  1. A GAP IS DATA. Gated-out seconds are written with their gate flags and a NULL score — never
//     omitted, never back-filled, never interpolated. `focus: null, state: "withheld"` is the most
//     important row in this file, because it is the one that says "I don't know."
//
//  2. SYNTHETIC IS DECLARED IN THE DATA. `synthetic: true` is set by the generator and by nothing
//     else, travels with the record in its JSON and in index.json's manifest, and gates Store.write
//     (a synthetic record with no `syntheticNote` is refused). See Synthetic/.
//

import Foundation

nonisolated let sessionSchemaVersion = 1

// MARK: - Epoch

/// One second of measured brain, downsampled from the engine's native 8 Hz.
///
/// The scores are OPTIONAL, and that is the whole point. `nil` means a gate was closed and there is
/// no trustworthy number for this second. It does not mean zero.
nonisolated struct Epoch: Codable, Equatable, Sendable {
    /// Seconds since the session start.
    var t: Double

    /// 0..100, or nil when withheld. 50 == this user's frozen baseline for THIS session.
    var focus: Double?
    /// 0..100 alpha share, or nil when withheld.
    var calm: Double?
    /// 0..100 jaw EMG load, or nil when withheld. 50 == this user's own resting jaw.
    var clench: Double?
    /// Raw Pope index. Recorded even when withheld, because it is the raw observation.
    var engagement: Double
    /// µV²/Hz per band.
    var bands: [String: Double]
    /// The Berger peak, 6–14 Hz. Nil when there is no peak.
    var alphaPeak: Double?
    /// Broadband RMS, µV, electrode-referred.
    var rmsUv: Double

    var signalOk: Bool
    var fsOk: Bool
    var calibrating: Bool

    var state: BrainState

    var trustworthy: Bool { signalOk && fsOk && !calibrating }

    // A gap is data. Swift's synthesised encoder OMITS nil optionals — so a withheld epoch would
    // silently lose its `focus` key, and a reader could not tell "withheld" from "this field didn't
    // exist in that schema version". We write an explicit `null` instead, so every second on disk
    // carries the same keys and an absent score is visibly a refusal, not a gap in the format.
    enum CodingKeys: String, CodingKey {
        case t, focus, calm, clench, engagement, bands, alphaPeak, rmsUv
        case signalOk, fsOk, calibrating, state
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        // `encode`, not `encodeIfPresent`: forces `"focus": null` when the value is nil.
        try c.encode(focus, forKey: .focus)
        try c.encode(calm, forKey: .calm)
        try c.encode(clench, forKey: .clench)
        try c.encode(engagement, forKey: .engagement)
        try c.encode(bands, forKey: .bands)
        try c.encode(alphaPeak, forKey: .alphaPeak)
        try c.encode(rmsUv, forKey: .rmsUv)
        try c.encode(signalOk, forKey: .signalOk)
        try c.encode(fsOk, forKey: .fsOk)
        try c.encode(calibrating, forKey: .calibrating)
        try c.encode(state, forKey: .state)
    }
}

// MARK: - Session

nonisolated struct DeviceInfo: Codable, Equatable, Sendable {
    var name: String
    var sps: Int
    var firmware: String?
    /// AD8422 instrumentation gain. The wire carries raw ADC counts; we scale them ourselves.
    var afeGain: Double = 100
}

nonisolated struct BaselineInfo: Codable, Equatable, Sendable {
    /// The frozen Pope index E0. 50 on the 0–100 scale means exactly this.
    var engagement: Double
    /// The frozen resting-jaw gamma share.
    var clench: Double?
    var frozenAt: Date
    /// True if E0 was carried over from an earlier session rather than measured in this one.
    /// Re-seating the earpad changes impedance, so a reused baseline is a WEAKER claim, and any
    /// view comparing across sessions has to say so.
    var reused: Bool = false
}

nonisolated struct SessionRecord: Codable, Equatable, Sendable, Identifiable {
    var schema: Int = sessionSchemaVersion
    var id: UUID = UUID()

    /// Set by Synthetic/ and by nothing else. See `Store.write` — it refuses to file a synthetic
    /// record anywhere a real one can be mistaken for it.
    var synthetic: Bool = false
    /// Why this synthetic session exists and how it was made. Nil for real sessions.
    var syntheticNote: String?

    var startedAt: Date
    var endedAt: Date
    var device: DeviceInfo
    var baseline: BaselineInfo?

    var epochs: [Epoch]
    var activities: [ActivitySpan]
    var markers: [Marker]

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Fraction of the session that produced a trustworthy score. The honest denominator.
    /// A session with 20% coverage is not a session, it is a cable problem.
    var coverage: Double {
        guard !epochs.isEmpty else { return 0 }
        return Double(epochs.filter(\.trustworthy).count) / Double(epochs.count)
    }

    func date(at t: Double) -> Date { startedAt.addingTimeInterval(t) }

    /// Epochs falling inside a span. Used by the rollup; withheld epochs are INCLUDED, because
    /// they are how coverage is computed.
    func epochs(in span: ActivitySpan) -> [Epoch] {
        epochs.filter { span.contains(date(at: $0.t)) }
    }
}

// MARK: - Coding

/// ISO-8601 with fractional seconds, everywhere, so the JSON is unambiguous in any timezone.
nonisolated func neurosyncEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
}

nonisolated func neurosyncDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}
