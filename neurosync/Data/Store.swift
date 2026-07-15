//
//  Store.swift
//  neurosync
//
//  ~/Desktop/neurosync-local/ — plain JSON on the Desktop, where you can open it, read it, diff it,
//  and delete it. No database, no iCloud, no server. The data is yours and it is legible.
//
//      neurosync-local/
//        index.json                        schema version + a manifest of what exists
//        sessions/<iso8601>--<uuid>.json   one file per session
//        days/<yyyy-mm-dd>.json            derived rollups — regenerable, safe to delete
//        markers.jsonl                     append-only self-report log
//
//  APP SANDBOX IS ON, so the Desktop is not ours to write to by default. Two routes, in order:
//
//    1. The `temporary-exception.files.home-relative-path.read-write` entitlement, scoped to
//       `Desktop/neurosync-local/`. Silent, no UI, lands exactly where asked.
//    2. If that is refused at runtime (an unsigned build, a hardened profile), fall back to an
//       NSOpenPanel and keep a security-scoped bookmark in UserDefaults.
//
//  Route 1 is tried by WRITING, not by asking. Sandbox denial shows up as a thrown error at the
//  first write, never as a queryable capability.
//

import Foundation

nonisolated enum StoreError: Error, LocalizedError {
    case noLocation
    case sandboxDenied(String)
    case refusedSyntheticLeak

    var errorDescription: String? {
        switch self {
        case .noLocation:
            return "No data folder has been granted. Choose one to start recording."
        case .sandboxDenied(let path):
            return "The sandbox refused \(path). Grant a folder instead."
        case .refusedSyntheticLeak:
            return "Refused to file a synthetic session as real data."
        }
    }
}

/// Everything on disk. `@MainActor` because it owns a security-scoped bookmark and talks to
/// NSOpenPanel; the writes themselves are cheap and infrequent (once per second, at most).
@MainActor
final class Store {
    static let folderName = "neurosync-local"
    private static let bookmarkKey = "neurosync.dataFolderBookmark"

    private(set) var root: URL?

    /// The security-scoped URL we hold access to, if any.
    ///
    /// `nonisolated(unsafe)` because `deinit` is nonisolated and must be able to release the scope.
    /// It is only ever WRITTEN on the main actor, and read exactly once more, at teardown. Do NOT
    /// reach for `MainActor.assumeIsolated` here: a `deinit` can run on whatever thread happens to
    /// drop the last reference, and `assumeIsolated` traps — killing the process — when it does not
    /// land on main. That failure shows up as the app mysteriously dying after the work is done.
    private nonisolated(unsafe) var scopedRoot: URL?

    /// The REAL home directory — `/Users/<you>`, not the sandbox container.
    ///
    /// Under App Sandbox, `FileManager.homeDirectoryForCurrentUser` and `NSHomeDirectory()` both
    /// return `~/Library/Containers/<bundle>/Data`. Writing "Desktop/neurosync-local" under THAT
    /// lands the folder inside the container, where the user will never find it. `getpwuid` reports
    /// the true home even inside the sandbox, and the
    /// `temporary-exception.files.home-relative-path.read-write` entitlement is specifically what
    /// makes `~/Desktop/neurosync-local` reachable from there.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = FileManager.default.string(withFileSystemRepresentation: dir, length: strlen(dir))
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The path the app WANTS: ~/Desktop/neurosync-local, on the REAL Desktop.
    static var preferredRoot: URL {
        realHome
            .appending(path: "Desktop", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    var sessionsDir: URL? { root?.appending(path: "sessions", directoryHint: .isDirectory) }
    var daysDir: URL? { root?.appending(path: "days", directoryHint: .isDirectory) }
    var markersFile: URL? { root?.appending(path: "markers.jsonl") }
    var indexFile: URL? { root?.appending(path: "index.json") }

    init() {
        root = resolveBookmark() ?? tryPreferredRoot()
    }

    // MARK: Location

    /// Try the entitlement route by actually creating the directory. Sandbox denial is an error at
    /// write time, not a flag you can read.
    private func tryPreferredRoot() -> URL? {
        let url = Self.preferredRoot
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Creating a directory can succeed under a sandbox that will still refuse the file, so
            // prove it with a real write.
            let probe = url.appending(path: ".neurosync-write-probe")
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
            return url
        } catch {
            return nil
        }
    }

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        scopedRoot = url
        return url
    }

    /// Persist a user-granted folder. Called after an NSOpenPanel in `DayView`.
    func grant(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw StoreError.sandboxDenied(url.path)
        }
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        scopedRoot = url
        root = url
        try ensureLayout()
    }

    var hasLocation: Bool { root != nil }

    private func ensureLayout() throws {
        guard let root else { throw StoreError.noLocation }
        for dir in [root,
                    root.appending(path: "sessions", directoryHint: .isDirectory),
                    root.appending(path: "days", directoryHint: .isDirectory)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        scopedRoot?.stopAccessingSecurityScopedResource()
    }

    // MARK: Sessions

    private static func filename(for s: SessionRecord) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = f.string(from: s.startedAt).replacingOccurrences(of: ":", with: "-")
        let tag = s.synthetic ? "SYNTHETIC--" : ""
        return "\(tag)\(stamp)--\(s.id.uuidString.prefix(8)).json"
    }

    @discardableResult
    func write(_ session: SessionRecord) throws -> URL {
        guard let sessionsDir else { throw StoreError.noLocation }
        try ensureLayout()

        // The wall, part one: a synthetic record announces itself in its FILENAME, so it is obvious
        // in Finder, in a `ls`, and in any script that ingests this folder — not only to a reader
        // who parses the JSON.
        if session.synthetic && session.syntheticNote == nil {
            throw StoreError.refusedSyntheticLeak
        }

        let url = sessionsDir.appending(path: Self.filename(for: session))
        let data = try neurosyncEncoder().encode(session)
        try data.write(to: url, options: .atomic)
        try writeIndex()
        return url
    }

    func loadSessions() throws -> [SessionRecord] {
        guard let sessionsDir,
              let files = try? FileManager.default.contentsOfDirectory(
                at: sessionsDir, includingPropertiesForKeys: nil
              ) else { return [] }

        let dec = neurosyncDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: Markers

    func append(_ marker: Marker) throws {
        guard let markersFile else { throw StoreError.noLocation }
        try ensureLayout()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try enc.encode(marker)
        line.append(0x0A)

        if FileManager.default.fileExists(atPath: markersFile.path) {
            let h = try FileHandle(forWritingTo: markersFile)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: markersFile, options: .atomic)
        }
    }

    func loadMarkers() throws -> [Marker] {
        guard let markersFile,
              let text = try? String(contentsOf: markersFile, encoding: .utf8) else { return [] }
        let dec = neurosyncDecoder()
        return text.split(separator: "\n").compactMap {
            try? dec.decode(Marker.self, from: Data($0.utf8))
        }
    }

    // MARK: Index

    nonisolated struct Index: Codable, Sendable {
        var schema: Int
        var generatedAt: Date
        var sessions: [Entry]
        /// Verbatim, in the data itself, so nobody has to take the app's word for it.
        var note: String

        nonisolated struct Entry: Codable, Sendable {
            var id: UUID
            var startedAt: Date
            var endedAt: Date
            var synthetic: Bool
            var coverage: Double
            var sps: Int
        }
    }

    private func writeIndex() throws {
        guard let indexFile else { throw StoreError.noLocation }
        let sessions = try loadSessions()
        let idx = Index(
            schema: sessionSchemaVersion,
            generatedAt: Date(),
            sessions: sessions.map {
                .init(id: $0.id, startedAt: $0.startedAt, endedAt: $0.endedAt,
                      synthetic: $0.synthetic, coverage: $0.coverage, sps: $0.device.sps)
            },
            note: """
            NeuroSync local data. Sessions with "synthetic": true were GENERATED, not measured — \
            their waveforms are artificial, though every score in them was computed by the same DSP \
            a real recording goes through. A null focus/calm/clench value means a gate was closed \
            and there is no trustworthy number for that second; it does not mean zero.
            """
        )
        try neurosyncEncoder().encode(idx).write(to: indexFile, options: .atomic)
    }
}
