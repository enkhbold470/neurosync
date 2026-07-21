//
//  SyntheticDays.swift
//  neurosync
//
//  Two scripted days of VOLTAGE, pushed through the real engine.
//
//  Read SyntheticSignal.swift's header first. The short version: this file writes spectra and
//  context, never scores. It says "the jaw was loud during the standup" and "alpha rose in the last
//  half-hour of the afternoon block". What that DOES to the focus number is decided by DSP.swift and
//  Focus.swift, and it is genuinely not decided here — I could not make this file print a 72 if I
//  wanted to, because it has no channel through which to say so.
//
//  Every session it produces is `synthetic: true` in its JSON and carries a `syntheticNote`
//  explaining how it was made; Store.write refuses it otherwise.
//
//  Two of the four things the day demonstrates are the app REFUSING to answer, and that is not
//  decoration either:
//
//    * Yesterday 08:40 — the board was left at 90 SPS. 60 Hz mains folds to 30 Hz there, straight
//      into beta, and cannot be notched. The whole block is withheld. Coverage 0%.
//    * Today 15:00 — the headset was adjusted mid-block. The electrode came off the skin, the RMS
//      fell under the noise floor, and the score froze rather than spiking to 100.
//    * Today's standup and yesterday's 1:1 — you were TALKING. The EMG lands in beta, so the raw
//      score climbs. The clench gate marks the window contaminated instead of calling it focus.
//    * Today 10:15 — you were still in the Claude-coding block, and alpha rose while engagement fell
//      under baseline. That is the daydream.
//

import Foundation

nonisolated let syntheticNote = """
GENERATED, NOT MEASURED. The waveform behind this session is artificial — pink noise, band-limited \
rhythms, EMG, blinks, 60 Hz mains and electrode-off stretches, produced by Synthetic/. No brain was \
involved. Every focus/calm/clench value in it was nonetheless COMPUTED by the same DSP, gates and \
state machine a real recording goes through; none was typed in. It exists so the Day view can be \
designed and reviewed without hardware. It must never be presented as a measurement.
"""

// MARK: - Script

private nonisolated struct SessionScript {
    var startHour: Int
    var startMinute: Int
    var fs: Double
    var durationSec: Double
    var blocks: [SynthBlock]
    var activities: [(kind: ActivityKind, label: String, source: ActivitySource, bundleId: String?, fromSec: Double, toSec: Double)]
    var markers: [(kind: MarkerKind, atSec: Double, note: String?)]
    var seed: UInt64
}

private nonisolated func at(_ day: Date, _ h: Int, _ m: Int, _ cal: Calendar) -> Date {
    cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
}

// MARK: - Build

/// Render one scripted session by generating counts and feeding them to a real `SessionRecorder`.
private nonisolated func render(_ s: SessionScript, day: Date, cal: Calendar) -> SessionRecord {
    let startedAt = at(day, s.startHour, s.startMinute, cal)

    let spans: [ActivitySpan] = s.activities.map {
        ActivitySpan(
            kind: $0.kind,
            label: $0.label,
            start: startedAt.addingTimeInterval($0.fromSec),
            end: startedAt.addingTimeInterval($0.toSec),
            source: $0.source,
            bundleId: $0.bundleId
        )
    }

    let markers: [Marker] = s.markers.map {
        Marker(kind: $0.kind, at: startedAt.addingTimeInterval($0.atSec), note: $0.note)
    }

    // The context the state machine needs, and the ONLY thing the script gets to say about meaning.
    let effortful: (Double) -> Bool = { t in
        spans.contains { $0.kind.isEffortful && t >= $0.start.timeIntervalSince(startedAt) && t < $0.end.timeIntervalSince(startedAt) }
    }

    let counts = synthesizeCounts(
        blocks: s.blocks, fs: s.fs, durationSec: s.durationSec, seed: s.seed
    )

    let rec = SessionRecorder(fs: s.fs, effortfulAt: effortful)
    for c in counts { rec.push(counts: c) }

    return rec.finish(
        startedAt: startedAt,
        device: DeviceInfo(name: Vertex.deviceName, sps: Int(s.fs), firmware: "v4"),
        activities: spans,
        markers: markers,
        synthetic: true,
        syntheticNote: syntheticNote
    )
}

// MARK: - The two days

/// Yesterday and today. Deterministic: the same seeds give the same days, byte for byte.
///
/// The seven sessions are wholly independent — each is its own seeded waveform through its own
/// engine, sharing no state — so they render CONCURRENTLY across the cores. This is the one place in
/// the whole feature where fan-out actually applies: the DSP is the cost, the sessions don't touch
/// each other, and `concurrentPerform` blocks until all are done so the result is still ordered and
/// deterministic. On an 8-core machine this is the difference between a one-off button press that
/// hangs and one that returns in a few seconds on a release build.
nonisolated func generateSyntheticDays(now: Date = Date(), calendar cal: Calendar = .current) -> [SessionRecord] {
    let today = cal.startOfDay(for: now)
    let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today

    let jobs = yesterdayScripts().map { ($0, yesterday) } + todayScripts().map { ($0, today) }

    // Preallocated slots keep the output order stable regardless of completion order.
    let box = RenderBox(count: jobs.count)
    DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
        let (script, day) = jobs[i]
        box.set(i, render(script, day: day, cal: cal))
    }
    return box.collect()
}

/// A tiny lock-guarded slot array. Each index is written exactly once, by exactly one worker, so the
/// only contention is the write itself — but a plain array is not safe to mutate from many threads,
/// so it goes through a lock.
private nonisolated final class RenderBox: @unchecked Sendable {
    private var slots: [SessionRecord?]
    private let lock = NSLock()

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ i: Int, _ r: SessionRecord) {
        lock.lock(); slots[i] = r; lock.unlock()
    }

    func collect() -> [SessionRecord] { slots.compactMap { $0 } }
}

// MARK: Yesterday

private nonisolated func yesterdayScripts() -> [SessionScript] {
    [
        // 08:40 — the board was left at 90 SPS after a bench test. 60 Hz mains folds to 30 Hz, dead
        // centre of beta, and cannot be notched. The signal is fine; the RATE is not. Every second
        // of this block is withheld, and the day view says so instead of scoring it.
        SessionScript(
            startHour: 8, startMinute: 40, fs: 90, durationSec: 600,
            blocks: [
                SynthBlock(startSec: 0, durationSec: 120, profile: .baseline, rampSec: 0),
                SynthBlock(startSec: 120, durationSec: 480, profile: .focused)
            ],
            activities: [(.coding, "Cursor", .appWatch, "com.todesktop.230313mzl4w4u92", 0, 600)],
            markers: [],
            seed: 0x5EED_0001
        ),

        // 10:00 — the good block. Clean, mostly engaged, with a genuine long flow run.
        SessionScript(
            startHour: 10, startMinute: 0, fs: 175, durationSec: 1800,
            blocks: [
                SynthBlock(startSec: 0, durationSec: 60, profile: .baseline, rampSec: 0),
                SynthBlock(startSec: 60, durationSec: 840, profile: .focused, rampSec: 60),
                SynthBlock(startSec: 900, durationSec: 180, profile: .baseline),
                SynthBlock(startSec: 1080, durationSec: 720, profile: .focused, rampSec: 45)
            ],
            activities: [
                (.coding, "Cursor", .appWatch, "com.todesktop.230313mzl4w4u92", 0, 900),
                (.browsing, "Chrome", .appWatch, "com.google.Chrome", 900, 1080),
                (.coding, "VS Code", .appWatch, "com.microsoft.VSCode", 1080, 1800)
            ],
            markers: [],
            seed: 0x5EED_0002
        ),

        // 13:30 — a 1:1. You talked the whole time. Temporalis EMG floods beta, the raw engagement
        // index CLIMBS, and the clench gate is the only thing standing between that and a headline
        // that says you concentrated harder in the meeting than you did all morning.
        SessionScript(
            startHour: 13, startMinute: 30, fs: 175, durationSec: 1200,
            blocks: [
                SynthBlock(startSec: 0, durationSec: 60, profile: .baseline, rampSec: 0),
                SynthBlock(startSec: 60, durationSec: 1080, profile: .talking, rampSec: 45),
                SynthBlock(startSec: 1140, durationSec: 60, profile: .baseline)
            ],
            activities: [(.onCall, "Zoom", .appWatch, "us.zoom.xos", 0, 1200)],
            markers: [],
            seed: 0x5EED_0003
        ),

        // 15:00 — the afternoon. Starts fine, decays into theta. The vigilance decrement, on a clean
        // electrode, with nothing to blame but the hour.
        SessionScript(
            startHour: 15, startMinute: 0, fs: 175, durationSec: 2400,
            blocks: [
                SynthBlock(startSec: 0, durationSec: 60, profile: .baseline, rampSec: 0),
                SynthBlock(startSec: 60, durationSec: 840, profile: .focused, rampSec: 60),
                SynthBlock(startSec: 900, durationSec: 420, profile: .baseline, rampSec: 120),
                SynthBlock(startSec: 1320, durationSec: 540, profile: .disengaged, rampSec: 180),
                SynthBlock(startSec: 1860, durationSec: 540, profile: .drowsy, rampSec: 180)
            ],
            activities: [
                (.coding, "VS Code", .appWatch, "com.microsoft.VSCode", 0, 900),
                (.comms, "iMessage", .appWatch, "com.apple.MobileSMS", 900, 1320),
                (.comms, "Telegram", .appWatch, "ru.keepcoder.Telegram", 1320, 1860),
                (.comms, "WhatsApp", .appWatch, "net.whatsapp.WhatsApp", 1860, 2400)
            ],
            markers: [
                (.coffee, 120, nil),
                (.breakTaken, 1320, "too much — stepped away"),
                (.walk, 1380, "went out for a walk"),
                (.stressed, 1500, "shipping the BLE reconnect fix, nothing works")
            ],
            seed: 0x5EED_0004
        )
    ]
}

// MARK: Today

private nonisolated func todayScripts() -> [SessionScript] {
    [
        // 09:05 — standup, then the Claude-coding block that starts strong and wanders off.
        SessionScript(
            startHour: 9, startMinute: 5, fs: 175, durationSec: 2400,
            blocks: [
                SynthBlock(startSec: 0, durationSec: 240, profile: .baseline, rampSec: 0),
                SynthBlock(startSec: 240, durationSec: 360, profile: .talking, rampSec: 30),
                SynthBlock(startSec: 600, durationSec: 120, profile: .baseline, rampSec: 45),
                SynthBlock(startSec: 720, durationSec: 900, profile: .focused, rampSec: 90),
                // Still in the coding block. Alpha rises, engagement falls under baseline: daydream.
                SynthBlock(startSec: 1620, durationSec: 660, profile: .disengaged, rampSec: 180),
                SynthBlock(startSec: 2280, durationSec: 120, profile: .baseline)
            ],
            activities: [
                (.onCall, "Zoom", .appWatch, "us.zoom.xos", 240, 600),
                (.coding, "Claude", .appWatch, "com.anthropic.claudefordesktop", 720, 1620),
                (.browsing, "Chrome", .appWatch, "com.google.Chrome", 1620, 2400)
            ],
            markers: [
                (.stressed, 2280, "can't hold the thread on this")
            ],
            seed: 0x5EED_0011
        ),

        // 11:30 — the design session. The best block of the two days: clean, sustained.
        SessionScript(
            startHour: 11, startMinute: 30, fs: 175, durationSec: 1800,
            blocks: [
                SynthBlock(startSec: 0, durationSec: 90, profile: .baseline, rampSec: 0),
                SynthBlock(startSec: 90, durationSec: 810, profile: .focused, rampSec: 90),
                SynthBlock(startSec: 900, durationSec: 120, profile: .disengaged, rampSec: 45),
                SynthBlock(startSec: 1020, durationSec: 780, profile: .focused, rampSec: 60)
            ],
            activities: [(.coding, "Cursor", .appWatch, "com.todesktop.230313mzl4w4u92", 0, 1800)],
            markers: [],
            seed: 0x5EED_0012
        ),

        // 14:10 — on call. Jaw set for most of it. Headset adjusted mid-block and the electrode came
        // off the skin for a few minutes: the score FREEZES, it does not spike to 100.
        SessionScript(
            startHour: 14, startMinute: 10, fs: 175, durationSec: 2400,
            blocks: [
                SynthBlock(startSec: 0, durationSec: 60, profile: .baseline, rampSec: 0),
                SynthBlock(startSec: 60, durationSec: 840, profile: .clenching, rampSec: 90),
                SynthBlock(startSec: 900, durationSec: 300, profile: .off, rampSec: 0),
                SynthBlock(startSec: 1200, durationSec: 780, profile: .baseline, rampSec: 45),
                SynthBlock(startSec: 1980, durationSec: 420, profile: .drowsy, rampSec: 180)
            ],
            activities: [
                (.onCall, "Zoom", .appWatch, "us.zoom.xos", 0, 1200),
                (.comms, "WhatsApp", .appWatch, "net.whatsapp.WhatsApp", 1200, 2400)
            ],
            markers: [
                (.anxious, 600, "pager went off twice"),
                (.coffee, 1300, nil)
            ],
            seed: 0x5EED_0013
        )
    ]
}
