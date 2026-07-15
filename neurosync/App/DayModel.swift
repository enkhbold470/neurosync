//
//  DayModel.swift
//  neurosync
//
//  Main-actor state for the Day view. Owns the Store; holds no signal processing of its own.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class DayModel {
    private(set) var days: [Day] = []
    private(set) var selectedKey: String?
    private(set) var error: String?
    private(set) var busy = false

    let store = Store()

    var selected: Day? {
        guard let selectedKey else { return days.last }
        return days.first { $0.key == selectedKey } ?? days.last
    }

    var hasLocation: Bool { store.hasLocation }
    var rootPath: String { store.root?.path ?? Store.preferredRoot.path }

    init() { load() }

    // MARK: Load

    func load() {
        guard store.hasLocation else { days = []; return }
        do {
            let sessions = try store.loadSessions()
            let loose = try store.loadMarkers()
            let cal = Calendar.current

            let grouped = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.startedAt) }

            days = grouped
                .map { date, sess in
                    // Markers live inside the session records; markers.jsonl is the live append log.
                    // Merge and de-duplicate, because a live session writes to both.
                    var ms = sess.flatMap(\.markers)
                    let known = Set(ms.map(\.id))
                    ms += loose.filter { cal.startOfDay(for: $0.at) == date && !known.contains($0.id) }
                    return rollUp(sessions: sess.sorted { $0.startedAt < $1.startedAt },
                                  markers: ms, date: date, calendar: cal)
                }
                .sorted { $0.date < $1.date }

            if selectedKey == nil || !days.contains(where: { $0.key == selectedKey }) {
                selectedKey = days.last?.key
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ key: String) { selectedKey = key }

    // MARK: Location

    /// The sandbox route of last resort. `Store` tries ~/Desktop/neurosync-local silently first; if
    /// the entitlement is not honoured at runtime, the user grants a folder here and we keep a
    /// security-scoped bookmark.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Grant"
        panel.message = "Choose where NeuroSync writes its data. ~/Desktop/\(Store.folderName) is the default."
        panel.directoryURL = Store.realHome.appending(path: "Desktop")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.grant(url)
            load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func revealInFinder() {
        guard let root = store.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: Synthetic

    /// Never called implicitly. There is no first-run seeding and no empty-state auto-fill — the
    /// empty state stays empty until someone deliberately presses the button.
    func generateSynthetic() {
        guard !busy else { return }
        busy = true
        error = nil

        Task.detached(priority: .userInitiated) {
            let records = generateSyntheticDays()
            await MainActor.run {
                do {
                    for r in records { try self.store.write(r) }
                    self.load()
                    self.selectedKey = self.days.last?.key
                } catch {
                    self.error = error.localizedDescription
                }
                self.busy = false
            }
        }
    }

    // MARK: Markers

    func mark(_ kind: MarkerKind, note: String? = nil) {
        do { try store.append(Marker(kind: kind, at: Date(), note: note)); load() }
        catch { self.error = error.localizedDescription }
    }
}
