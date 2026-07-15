//
//  ActivityWatcher.swift
//  neurosync
//
//  Where the context comes from, live.
//
//  Two observers, and both are deliberately narrow:
//
//    CalendarSource   EventKit, READ-ONLY. macOS Calendar already syncs Google Calendar, so real
//                     meetings and on-call blocks arrive with no OAuth, no API key and no token to
//                     leak. NeuroSync never creates, edits or deletes an event.
//
//    AppWatcher       The frontmost application's BUNDLE ID, sampled every 5 s. That is the entire
//                     surface: no window titles, no document names, no URLs, no keystrokes, no
//                     screen contents. It can tell that you were in Xcode. It cannot tell what you
//                     were writing, and it is not permitted to learn.
//
//  Neither one reads the EEG. The brain state is the dependent variable — if the context were
//  derived from the signal too, every finding in the Day view would be circular.
//

import AppKit
import EventKit
import Foundation

// MARK: - Calendar

@MainActor
final class CalendarSource {
    private let store = EKEventStore()
    private(set) var authorized = false
    private(set) var denied = false

    func requestAccess() async {
        do {
            authorized = try await store.requestFullAccessToEvents()
            denied = !authorized
        } catch {
            authorized = false
            denied = true
        }
    }

    /// Calendar events overlapping a window, as activity spans.
    ///
    /// All-day events are dropped: an all-day "On-call" block is a fact about the week, not about
    /// what you were doing at 14:12, and stretching it across the ribbon would swamp every real
    /// block underneath it.
    func spans(from: Date, to: Date) -> [ActivitySpan] {
        guard authorized else { return [] }

        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay }
            .compactMap { ev in
                guard let start = ev.startDate, let end = ev.endDate, end > start else { return nil }
                let title = ev.title ?? "Untitled"
                return ActivitySpan(
                    kind: activityForEvent(title: title, location: ev.location, url: ev.url?.absoluteString),
                    label: title,
                    start: max(start, from),
                    end: min(end, to),
                    source: .calendar,
                    bundleId: nil
                )
            }
    }
}

// MARK: - Frontmost app

@MainActor
final class AppWatcher {
    private var samples: [(at: Date, kind: ActivityKind, label: String, bundleId: String)] = []
    private var timer: Timer?

    /// True once we have seen at least one bundle id. If the sandbox ever stops handing them over,
    /// this stays false and the Day view says app-watching is unavailable rather than silently
    /// producing an empty lane that reads as "you did nothing".
    private(set) var working = false

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { self.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reset() { samples.removeAll() }

    private func sample() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier else { return }
        working = true
        samples.append((
            at: Date(),
            kind: activityForBundle(bundle),
            label: app.localizedName ?? bundle,
            bundleId: bundle
        ))
    }

    /// The observed spans so far, coalesced. See `coalesce` — a 20-second glance at Slack must not
    /// cut a two-hour coding block into three.
    var spans: [ActivitySpan] {
        coalesce(samples: samples)
    }
}

// MARK: - Combined

/// The context for one session: what the calendar said you would be doing, and what you were
/// actually looking at.
///
/// Calendar spans win on OVERLAP for the same kind — if the calendar says "Standup 09:15" and the
/// app watcher says "Zoom 09:16–09:29", that is one meeting, not two. When they disagree in kind,
/// both are kept: the calendar records the intent and the app watcher records the fact, and the
/// gap between them is often the most interesting thing on the ribbon.
@MainActor
final class ActivityWatcher {
    let calendar = CalendarSource()
    let apps = AppWatcher()

    private var startedAt: Date?

    func begin() {
        startedAt = Date()
        apps.reset()
        apps.start()
        Task { await calendar.requestAccess() }
    }

    func end() {
        apps.stop()
    }

    var appWatchAvailable: Bool { apps.working }
    var calendarAvailable: Bool { calendar.authorized }

    /// Everything observed since `begin()`.
    func spans(until: Date = Date()) -> [ActivitySpan] {
        guard let startedAt else { return [] }

        let observed = apps.spans
        let scheduled = calendar.spans(from: startedAt, to: until)

        // Drop an observed span that is fully inside a scheduled block of the same kind — the
        // calendar's label ("Standup") is more useful than the app's ("zoom.us").
        let deduped = observed.filter { obs in
            !scheduled.contains { sch in
                sch.kind == obs.kind && sch.start <= obs.start && sch.end >= obs.end
            }
        }

        return (scheduled + deduped).sorted { $0.start < $1.start }
    }
}
