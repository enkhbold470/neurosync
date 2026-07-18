//
//  CloudSync.swift
//  neurosync
//
//  Local-first cloud sync. The Mac's JSON at ~/Desktop/neurosync-local/ stays the SOURCE OF TRUTH;
//  the cloud is a one-way mirror. This is an upload queue, not live sync: on launch (and after a
//  session seals) it diffs the local sessions against a persisted cursor and uploads only what's new
//  or changed. Uploads are idempotent — keyed by the session UUID server-side — so retrying is safe.
//
//  Manifesto guarantees, preserved:
//    • Synthetic sessions are NEVER uploaded (`Store.loadSessions` already excludes them by flag, and
//      we re-check `synthetic` here).
//    • A withheld score stays `nil` through the JSON round-trip — `SessionRecord`'s own encoder forces
//      explicit null; the uploader must not coerce it to 0.
//    • The menu bar still reads the live model only. This reads persisted data for UPLOAD, which is a
//      separate path and never feeds a live surface.
//
//  Transport is behind `CloudUploader`. The default is a no-op; a real Convex uploader is wired once
//  ConvexMobile + auth are added (see CLOUD_SETUP.md). Everything here compiles with no dependency.
//

import Foundation

/// The network transport. Implemented by a Convex-backed uploader once the SDK + auth are wired.
nonisolated protocol CloudUploader: Sendable {
    /// Upsert one session (metadata + epoch chunks) idempotently by its UUID. Throws on failure so the
    /// queue can stop and retry later; the local file remains the durable copy.
    func upload(_ record: SessionRecord) async throws
    /// Whether a user is signed in and uploads may proceed.
    var isReady: Bool { get async }
}

/// The default: cloud sync is off. No network, no account, no-op.
nonisolated struct DisabledUploader: CloudUploader {
    func upload(_ record: SessionRecord) async throws {}
    var isReady: Bool { get async { false } }
}

/// Persisted record of what's already been mirrored, so we upload each session once (and again only
/// if it changed). Keyed by UUID string → last-uploaded `endedAt` epoch seconds.
@MainActor
final class CloudCursor {
    private let key = "neurosync.cloud.syncedSessions"
    private var synced: [String: Double]

    init() {
        synced = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    func needsUpload(_ r: SessionRecord) -> Bool {
        guard let uploadedAt = synced[r.id.uuidString] else { return true }
        return uploadedAt < r.endedAt.timeIntervalSince1970
    }

    func mark(_ r: SessionRecord) {
        synced[r.id.uuidString] = r.endedAt.timeIntervalSince1970
        UserDefaults.standard.set(synced, forKey: key)
    }
}

/// Drives the upload queue. Off unless a deployment is configured and the uploader is ready, so by
/// default this is a genuine no-op that never even reads the disk.
@MainActor
final class CloudSyncController {
    private let store: Store
    private let uploader: CloudUploader
    private let cursor = CloudCursor()
    private var running = false

    init(store: Store, uploader: CloudUploader = DisabledUploader()) {
        self.store = store
        self.uploader = uploader
    }

    /// Upload any local sessions the cloud hasn't seen yet. Safe to call repeatedly (on launch, after
    /// a session is written). Never uploads synthetic sessions.
    func syncPending() async {
        guard CloudConfig.isConfigured, store.hasLocation, !running else { return }
        guard await uploader.isReady else { return }
        running = true
        defer { running = false }

        let sessions = (try? store.loadSessions()) ?? []
        for r in sessions where !r.synthetic && cursor.needsUpload(r) {
            do {
                try await uploader.upload(r)
                cursor.mark(r)
            } catch {
                NSLog("cloud sync: upload deferred for \(r.id) — \(error.localizedDescription)")
                break   // stop on first failure; the local file is durable, retry next launch
            }
        }
    }
}
