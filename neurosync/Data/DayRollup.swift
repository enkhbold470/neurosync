//
//  DayRollup.swift
//  neurosync
//
//  Sessions + context → a day you can read.
//
//  This file is where the app is most tempted to lie, so it is where the rules are strictest:
//
//  * COVERAGE IS ALWAYS REPORTED. A block that is 80% withheld has a median focus computed from the
//    other 20%, and printing that number without the coverage beside it is the single most
//    misleading thing this app could do.
//  * WITHHELD SECONDS ARE NEVER INTERPOLATED. They are not zero, they are not the last good value,
//    and they are not averaged away. They are absent, and absence is drawn as absence.
//  * CLENCHED SECONDS ARE NOT CONCENTRATION. They are excluded from "time in flow" even when the
//    focus number is high, because that number is temporalis EMG.
//  * EVERY FINDING CARRIES ITS CONFOUND. Difficulty, fatigue and time of day are not controlled,
//    the sample is one person on one day, and the text says so rather than implying otherwise.
//

import Foundation

// MARK: - Segment

/// One activity block, scored.
nonisolated struct Segment: Identifiable, Sendable {
    var id: UUID { span.id }
    var span: ActivitySpan

    var epochCount: Int
    var trustedCount: Int

    /// Median of the TRUSTED focus values only. Nil if nothing in this block was trustworthy.
    var medianFocus: Double?
    var medianCalm: Double?
    var medianClench: Double?

    /// Fractions of TRUSTED time (not wall time) in each state.
    var stateShare: [BrainState: Double]

    /// Fraction of wall time that produced a trustworthy score.
    var coverage: Double

    /// Longest unbroken run of `.focused`, in seconds.
    var longestFlowSec: Double

    var duration: TimeInterval { span.duration }

    func share(_ s: BrainState) -> Double { stateShare[s] ?? 0 }

    /// Is there enough trusted signal here to say anything at all? Below this we print the coverage
    /// and refuse the verdict.
    var sayable: Bool { coverage >= 0.35 && trustedCount >= 30 }
}

// MARK: - Findings

nonisolated enum FindingTone: String, Sendable {
    case bad, good, caution, neutral

    /// SF Symbol for the glanceable layer.
    var icon: String {
        switch self {
        case .bad: return "exclamationmark.triangle.fill"
        case .good: return "checkmark.seal.fill"
        case .caution: return "exclamationmark.circle.fill"
        case .neutral: return "info.circle.fill"
        }
    }
}

nonisolated struct Finding: Identifiable, Sendable {
    var id = UUID()
    var tone: FindingTone
    var headline: String
    /// The caveat. Never nil, never empty — a finding without its confound is a claim.
    var caveat: String
}

/// The standing footer. Printed under every findings list, always.
nonisolated let confoundFooter = """
Association only. Difficulty, fatigue and time of day are not controlled, and this is one person on \
one day. A hard problem lowers measured focus and takes longer — the block did not cause the score.
"""

// MARK: - Day

nonisolated struct Day: Identifiable, Sendable {
    var id: String { key }
    /// yyyy-MM-dd, in the local calendar.
    var key: String
    var date: Date
    var sessions: [SessionRecord]
    var segments: [Segment]
    var markers: [Marker]
    var findings: [Finding]

    /// True if ANY session in the day is synthetic. The flag propagates from the session records
    /// so a day mixing a real session with a generated one is never reported as fully real.
    var synthetic: Bool { sessions.contains { $0.synthetic } }

    var coverage: Double {
        let all = sessions.flatMap(\.epochs)
        guard !all.isEmpty else { return 0 }
        return Double(all.filter(\.trustworthy).count) / Double(all.count)
    }

    var trustedEpochs: [Epoch] { sessions.flatMap(\.epochs).filter(\.trustworthy) }

    // MARK: Derived proxies
    //
    // These are the Neurable/Emotiv-shaped panels. They are PROXIES built from what an around-ear
    // channel can see, and they are labelled as proxies everywhere they appear.
    //
    // What they are NOT: frontal midline theta. FMθ is the best-validated cognitive-effort marker
    // in the literature — and it is sourced to anterior cingulate and read at Fz. An around-ear pad
    // physically cannot reach frontal midline. Any product claiming FMθ from an earbud is either
    // using a trained cross-channel estimator or making it up. We do neither, so we say neither.

    /// 0..100. Alpha suppression relative to your own calm baseline, plus jaw load.
    /// High = you were working hard and/or tense. NOT a clinical stress measure.
    var cognitiveStrainProxy: Double? {
        let e = trustedEpochs
        guard e.count >= 60 else { return nil }
        let suppression = e.compactMap { $0.calm.map { max(0, 100 - $0) } }
        let load = e.compactMap(\.clench)
        guard !suppression.isEmpty, !load.isEmpty else { return nil }
        return min(100, 0.6 * median(suppression) + 0.4 * median(load))
    }

    /// 0..100. The share of trusted time spent in `.calm` — actual recovery, not the absence of work.
    var mentalRecoveryProxy: Double? {
        let e = trustedEpochs
        guard e.count >= 60 else { return nil }
        let calm = e.filter { $0.state == .calm }.count
        return 100 * Double(calm) / Double(e.count)
    }

    /// The individual alpha frequency — the Berger peak, median over trusted time.
    /// This one is REAL: IAF is a genuine per-subject constant and the literature supports it.
    var individualAlphaFreq: Double? {
        let peaks = trustedEpochs.compactMap(\.alphaPeak)
        return peaks.count >= 30 ? median(peaks) : nil
    }

    var totalFocusedSec: Double {
        Double(sessions.flatMap(\.epochs).filter { $0.state == .focused }.count)
    }
    var totalDaydreamSec: Double {
        Double(sessions.flatMap(\.epochs).filter { $0.state == .daydream }.count)
    }
    var totalClenchedSec: Double {
        Double(sessions.flatMap(\.epochs).filter { $0.state == .clenched }.count)
    }
}

// MARK: - Build

nonisolated func segment(_ session: SessionRecord, span: ActivitySpan) -> Segment {
    let eps = session.epochs(in: span)
    let trusted = eps.filter(\.trustworthy)

    var share: [BrainState: Double] = [:]
    if !trusted.isEmpty {
        for st in BrainState.allCases where st != .withheld {
            let n = trusted.filter { $0.state == st }.count
            share[st] = Double(n) / Double(trusted.count)
        }
    }

    // Longest unbroken .focused run. Epochs are 1 Hz, so the count IS the seconds — but a withheld
    // epoch BREAKS the run rather than being skipped over. A 20-minute "flow block" that is really
    // two 3-minute blocks either side of a dead electrode is not a 20-minute flow block.
    var longest = 0.0, run = 0.0
    for e in eps {
        if e.state == .focused { run += 1; longest = max(longest, run) } else { run = 0 }
    }

    return Segment(
        span: span,
        epochCount: eps.count,
        trustedCount: trusted.count,
        medianFocus: trusted.isEmpty ? nil : median(trusted.compactMap(\.focus)),
        medianCalm: trusted.isEmpty ? nil : median(trusted.compactMap(\.calm)),
        medianClench: trusted.isEmpty ? nil : median(trusted.compactMap(\.clench)),
        stateShare: share,
        coverage: eps.isEmpty ? 0 : Double(trusted.count) / Double(eps.count),
        longestFlowSec: longest
    )
}

nonisolated func rollUp(sessions: [SessionRecord], markers: [Marker], date: Date, calendar: Calendar = .current) -> Day {
    let f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = "yyyy-MM-dd"

    let segs = sessions
        .flatMap { s in s.activities.map { segment(s, span: $0) } }
        .sorted { $0.span.start < $1.span.start }

    var day = Day(
        key: f.string(from: date),
        date: date,
        sessions: sessions,
        segments: segs,
        markers: markers.sorted { $0.at < $1.at },
        findings: []
    )
    day.findings = findings(for: day)
    return day
}

// MARK: - The findings engine

/// "If focus is fucked up, just say so, and mark it during the specific moment."
///
/// Every branch here either prints a number with its coverage, or refuses to print a number and
/// says why. There is no third option.
nonisolated func findings(for day: Day) -> [Finding] {
    var out: [Finding] = []

    // Coverage first. If the day barely recorded, nothing below it means anything and saying so is
    // more useful than a confident median over four good minutes.
    if !day.sessions.isEmpty && day.coverage < 0.5 {
        out.append(Finding(
            tone: .caution,
            headline: String(
                format: "Only %.0f%% of the day produced a trustworthy score.",
                day.coverage * 100),
            caveat: "The rest was gated out — no biosignal, or still calibrating. Read everything below with that in mind: the medians are computed from the part that worked."
        ))
    }

    for seg in day.segments where seg.span.kind.isEffortful {
        let name = seg.span.label.uppercased()
        let window = "\(clock(seg.span.start))–\(clock(seg.span.end))"

        guard seg.sayable else {
            if seg.duration >= 300 {
                out.append(Finding(
                    tone: .caution,
                    headline: String(
                        format: "%@ (%@) has only %.0f%% coverage — no verdict.",
                        name, window, seg.coverage * 100),
                    caveat: "Too much of this block was gated out to say anything about it. That is a refusal, not a zero."
                ))
            }
            continue
        }

        // The headline case: sub-baseline focus during a block you meant to concentrate in.
        if let mf = seg.medianFocus, mf < 45 {
            let mins = Int(seg.duration / 60)
            out.append(Finding(
                tone: .bad,
                headline: String(
                    format: "Focus sat below your baseline through %@ (%@, %dm) — median %.0f against a baseline of 50.",
                    name, window, mins, mf),
                caveat: String(
                    format: "Coverage %.0f%%. %.0f%% of the trusted time in this block read as mind-wandering.",
                    seg.coverage * 100, seg.share(.daydream) * 100)
            ))
        }

        // Mind-wandering, called out even when the median held up — a block can average fine and
        // still be half daydream.
        if seg.share(.daydream) >= 0.30 {
            out.append(Finding(
                tone: .bad,
                headline: String(
                    format: "%.0f%% of %@ (%@) read as mind-wandering.",
                    seg.share(.daydream) * 100, name, window),
                caveat: "Engagement well under your baseline with alpha rising, on a clean signal and a quiet jaw. That is the mind-wandering signature — it is a candidate, not proof of what you were thinking about."
            ))
        }

        // The contamination warning. This one matters more than it looks: it is the app admitting
        // its own number is unreliable in a window, which no competitor does.
        if seg.share(.clenched) >= 0.15 {
            out.append(Finding(
                tone: .caution,
                headline: String(
                    format: "Jaw was tense for %.0f%% of %@ (%@).",
                    seg.share(.clenched) * 100, name, window),
                caveat: "Temporalis EMG lands in beta, which is the focus numerator. Treat the focus number in this window as contaminated — clenching and concentrating are the same signal on one channel."
            ))
        }

        // And the good news, held to the same standard.
        if seg.longestFlowSec >= 600 {
            out.append(Finding(
                tone: .good,
                headline: String(
                    format: "%d min of unbroken flow during %@ (%@).",
                    Int(seg.longestFlowSec / 60), name, window),
                caveat: String(
                    format: "Unbroken means unbroken: a withheld second ends the run. Coverage %.0f%%.",
                    seg.coverage * 100)
            ))
        }
    }

    // Self-reported markers, matched to what the signal was doing around them. This is the only
    // place stress and anxiety appear, and they appear as YOUR WORDS, not as a measurement.
    for m in day.markers where m.kind == .stressed || m.kind == .anxious {
        let around = day.trustedEpochs.filter { e in
            guard let s = day.sessions.first(where: { $0.epochs.contains(e) }) else { return false }
            let t = s.date(at: e.t)
            return abs(t.timeIntervalSince(m.at)) <= 300
        }
        let clench = around.compactMap(\.clench)
        if clench.count >= 30 {
            out.append(Finding(
                tone: .neutral,
                headline: String(
                    format: "You logged %@ at %@. Jaw load in the 10 min around it: %.0f.",
                    m.kind.label.lowercased(), clock(m.at), median(clench)),
                caveat: "You reported the feeling; the instrument only measured your jaw. 50 is your own resting baseline. This is a coincidence in time, not a reading of an emotion — one around-ear channel cannot measure stress or anxiety."
            ))
        }
    }

    if day.sessions.isEmpty {
        out.append(Finding(
            tone: .neutral,
            headline: "Nothing was recorded on this day.",
            caveat: "No board, no data. There is no demo mode."
        ))
    }

    return out
}

nonisolated func clock(_ d: Date, calendar: Calendar = .current) -> String {
    let f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}

/// HH:mm:ss — for the ruler and scrubber when zoomed in past the minute scale.
nonisolated func clockSec(_ d: Date, calendar: Calendar = .current) -> String {
    let f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}
