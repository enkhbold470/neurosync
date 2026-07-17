//
//  Activity.swift
//  neurosync
//
//  What you were DOING, next to what your brain was doing.
//
//  Three sources, and the source is always recorded, because it is the difference between a fact
//  and a guess:
//
//    .calendar   an event in macOS Calendar (Google Calendar syncs into it) — scheduled, so it is
//                what you INTENDED to be doing.
//    .appWatch   the frontmost application's bundle id — OBSERVED, so it is what you were actually
//                looking at. Bundle id only. No window titles, no keystrokes, no screen content.
//    .self       you pressed a key. Self-report. This is where "too much stress, took a break" and
//                "went for a walk" live, because that is exactly what they are.
//
//  Nothing here is inferred from EEG. The brain state is the dependent variable; if the context
//  were derived from it too, every finding would be circular.
//

import Foundation

// MARK: - Kinds

nonisolated enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case coding
    case design
    case meeting
    case onCall
    case comms
    case reading
    case browsing
    case breakTime
    case walk
    case unknown

    var label: String {
        switch self {
        case .coding: return "CODING"
        case .design: return "DESIGN"
        case .meeting: return "MEETING"
        case .onCall: return "ON CALL"
        case .comms: return "COMMS"
        case .reading: return "READING"
        case .browsing: return "BROWSING"
        case .breakTime: return "BREAK"
        case .walk: return "WALK"
        case .unknown: return "OTHER"
        }
    }

    /// SF Symbol — the glanceable layer. Humans read the icon; agents read `label`.
    var icon: String {
        switch self {
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .design: return "paintbrush.pointed.fill"
        case .meeting: return "video.fill"
        case .onCall: return "phone.badge.waveform.fill"
        case .comms: return "bubble.left.and.bubble.right.fill"
        case .reading: return "book.fill"
        case .browsing: return "globe"
        case .breakTime: return "pause.circle.fill"
        case .walk: return "figure.walk"
        case .unknown: return "app.dashed"
        }
    }

    /// Blocks you were *supposed* to be concentrating in. Only these can produce a "focus fell
    /// apart here" finding — a low score during a walk is not a problem, it is a walk.
    var isEffortful: Bool {
        switch self {
        case .coding, .design, .meeting, .onCall, .reading: return true
        case .comms, .browsing, .breakTime, .walk, .unknown: return false
        }
    }
}

nonisolated enum ActivitySource: String, Codable, Sendable {
    case calendar
    case appWatch
    case selfReport

    var label: String {
        switch self {
        case .calendar: return "calendar"
        case .appWatch: return "observed"
        case .selfReport: return "self-reported"
        }
    }
}

// MARK: - Spans

nonisolated struct ActivitySpan: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: ActivityKind
    /// The human name. From the calendar event title, the app name, or what you typed.
    var label: String
    var start: Date
    var end: Date
    var source: ActivitySource
    /// Bundle id, for `.appWatch` spans. Nil otherwise.
    var bundleId: String?

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func overlaps(_ other: ActivitySpan) -> Bool {
        start < other.end && other.start < end
    }

    func contains(_ t: Date) -> Bool { t >= start && t < end }
}

// MARK: - Markers

/// A self-reported instant. Never derived, never inferred.
///
/// STRESS AND ANXIETY LIVE HERE AND ONLY HERE. One around-ear dry channel cannot measure either —
/// beta overlaps jaw, temporalis and neck EMG, so clenching your teeth and concentrating are the
/// same signal. A number labelled "anxiety" coming off this hardware would be invented. So the app
/// does not invent one: you tell it, and it records that you told it.
nonisolated enum MarkerKind: String, Codable, CaseIterable, Sendable {
    case stressed
    case anxious
    case breakTaken
    case walk
    case coffee
    case note

    var label: String {
        switch self {
        case .stressed: return "STRESSED"
        case .anxious: return "ANXIOUS"
        case .breakTaken: return "BREAK"
        case .walk: return "WALK"
        case .coffee: return "COFFEE"
        case .note: return "NOTE"
        }
    }

    var glyph: String {
        switch self {
        case .stressed: return "bolt.fill"
        case .anxious: return "waveform.path"
        case .breakTaken: return "pause.fill"
        case .walk: return "figure.walk"
        case .coffee: return "cup.and.saucer.fill"
        case .note: return "text.alignleft"
        }
    }
}

nonisolated struct Marker: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: MarkerKind
    var at: Date
    var note: String?
    /// Always `.selfReport`. Present so the JSON is self-describing to anyone reading it cold.
    var source: ActivitySource = .selfReport
}

// MARK: - Classification

/// Frontmost-app bundle id → what you were doing.
///
/// Prefix-matched, so `com.anthropic.claude.helper` still reads as coding. Anything unrecognised is
/// `.unknown` rather than a guess.
nonisolated let bundleActivityMap: [(prefix: String, kind: ActivityKind)] = [
    ("com.anthropic.claude", .coding),
    ("com.todesktop.230313mzl4w4u92", .coding),   // Cursor
    ("com.apple.dt.Xcode", .coding),
    ("com.microsoft.VSCode", .coding),
    ("com.microsoft.VSCodeInsiders", .coding),
    ("com.jetbrains", .coding),
    ("com.apple.Terminal", .coding),
    ("com.googlecode.iterm2", .coding),
    ("dev.warp.Warp", .coding),
    ("net.kovidgoyal.kitty", .coding),
    ("com.github.GitHubClient", .coding),

    ("com.figma.Desktop", .design),
    ("com.bohemiancoding.sketch3", .design),
    ("com.adobe", .design),
    ("com.linear", .design),

    ("us.zoom.xos", .meeting),
    ("com.microsoft.teams", .meeting),
    ("com.hnc.Discord", .meeting),
    ("com.pigeon.Around", .meeting),

    ("com.tinyspeck.slackmacgap", .comms),
    ("com.apple.mail", .comms),
    ("com.superhuman", .comms),

    ("com.readdle", .reading),
    ("com.apple.Preview", .reading),
    ("net.ia.writer", .reading),
    ("md.obsidian", .reading),

    ("com.apple.Safari", .browsing),
    ("com.google.Chrome", .browsing),
    ("company.thebrowser.Browser", .browsing),   // Arc
    ("org.mozilla.firefox", .browsing)
]

nonisolated func activityForBundle(_ bundleId: String) -> ActivityKind {
    for (prefix, kind) in bundleActivityMap where bundleId.hasPrefix(prefix) {
        return kind
    }
    return .unknown
}

/// Calendar event → what you were doing, from its title, location and URL.
///
/// A Zoom link in the location field is the single most reliable meeting tell there is.
nonisolated func activityForEvent(title: String, location: String?, url: String?) -> ActivityKind {
    let hay = [title, location ?? "", url ?? ""].joined(separator: " ").lowercased()

    if hay.contains("on-call") || hay.contains("oncall") || hay.contains("on call") { return .onCall }
    if hay.contains("zoom.us") || hay.contains("meet.google") || hay.contains("teams.microsoft")
        || hay.contains("1:1") || hay.contains("standup") || hay.contains("stand-up")
        || hay.contains("sync") || hay.contains("interview") || hay.contains("call") {
        return .meeting
    }
    if hay.contains("design") || hay.contains("figma") || hay.contains("crit") { return .design }
    if hay.contains("lunch") || hay.contains("break") { return .breakTime }
    if hay.contains("walk") || hay.contains("gym") || hay.contains("run") { return .walk }
    if hay.contains("review") || hay.contains("read") { return .reading }
    if hay.contains("code") || hay.contains("build") || hay.contains("ship") { return .coding }

    return .unknown
}

// MARK: - Coalescing

/// Turn a stream of frontmost-app samples into spans.
///
/// Samples arrive every few seconds. Raw, they are useless: a glance at Slack mid-session would cut
/// a two-hour coding block into three. So: runs shorter than `minSpanSec` are dropped, and two runs
/// of the same kind separated by less than `mergeGapSec` are merged.
nonisolated func coalesce(
    samples: [(at: Date, kind: ActivityKind, label: String, bundleId: String)],
    minSpanSec: TimeInterval = 60,
    mergeGapSec: TimeInterval = 30,
    sampleInterval: TimeInterval = 5
) -> [ActivitySpan] {
    guard !samples.isEmpty else { return [] }
    let sorted = samples.sorted { $0.at < $1.at }

    var runs: [ActivitySpan] = []
    var runStart = sorted[0].at
    var runKind = sorted[0].kind
    var runLabel = sorted[0].label
    var runBundle = sorted[0].bundleId
    var last = sorted[0].at

    func close(_ end: Date) {
        runs.append(ActivitySpan(
            kind: runKind, label: runLabel, start: runStart, end: end,
            source: .appWatch, bundleId: runBundle
        ))
    }

    for s in sorted.dropFirst() {
        if s.kind != runKind {
            close(last.addingTimeInterval(sampleInterval))
            runStart = s.at
            runKind = s.kind
            runLabel = s.label
            runBundle = s.bundleId
        }
        last = s.at
    }
    close(last.addingTimeInterval(sampleInterval))

    // Drop the noise BEFORE merging, not after.
    //
    // Order matters and it is easy to get backwards. A 20-second glance at Slack in the middle of a
    // two-hour coding session produces runs [coding, comms, coding]. Merge first and the two coding
    // runs are not adjacent — the comms run sits between them — so nothing merges, and the block
    // comes out shattered into three. Drop the sub-threshold runs first and the two coding runs
    // become neighbours separated by a small gap, which is exactly what the merge step is for.
    let survivors = runs.filter { $0.duration >= mergeGapSec }

    var merged: [ActivitySpan] = []
    for run in survivors {
        if var prev = merged.last,
           prev.kind == run.kind,
           run.start.timeIntervalSince(prev.end) <= max(mergeGapSec, minSpanSec) {
            prev.end = run.end
            merged[merged.count - 1] = prev
        } else {
            merged.append(run)
        }
    }

    return merged.filter { $0.duration >= minSpanSec }
}
