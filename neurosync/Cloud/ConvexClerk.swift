//
//  ConvexClerk.swift
//  neurosync
//
//  The real cloud transport: Convex sync + Clerk email auth. Created once at launch ONLY when a
//  deployment URL and a Clerk publishable key are both present; otherwise `client` is nil and the app
//  stays fully local-first. Auth is automatic — once the user signs in through Clerk, the token is
//  synced to Convex by `ClerkConvexAuthProvider`.
//
//  The uploader mirrors the local JSON to the cloud. It preserves the two invariants that matter:
//    • a withheld score is sent as `nil` → Convex null, NEVER 0 (ConvexEncodable encodes optionals).
//    • synthetic sessions are never uploaded (the CloudSyncController filters them before calling).
//

import Foundation
import Combine
import ConvexMobile
import ClerkConvex
import ClerkKit

@MainActor
@Observable
final class ConvexCloud {
    let client: ConvexClientWithAuth<String>?
    private(set) var signedIn = false
    @ObservationIgnored private var bag = Set<AnyCancellable>()

    init() {
        guard let url = CloudConfig.convexURL, let pk = CloudConfig.clerkPublishableKey else {
            client = nil
            return
        }
        Clerk.configure(publishableKey: pk)
        let c = ConvexClientWithAuth<String>(
            deploymentUrl: url.absoluteString,
            authProvider: ClerkConvexAuthProvider()
        )
        client = c
        c.authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .authenticated = state { self?.signedIn = true } else { self?.signedIn = false }
            }
            .store(in: &bag)
    }

    /// The uploader the local-first sync queue drives. Real when configured, no-op otherwise.
    var uploader: CloudUploader {
        if let client {
            return ConvexUploader(client: client, isSignedIn: { [weak self] in self?.signedIn ?? false })
        }
        return DisabledUploader()
    }
}

/// Mirrors a local `SessionRecord` to Convex: one `upsertSession`, then the epochs in ~60-second
/// chunks. Idempotent server-side by the session UUID, so retries are safe.
struct ConvexUploader: CloudUploader {
    let client: ConvexClientWithAuth<String>
    let isSignedIn: () -> Bool

    var isReady: Bool { isSignedIn() }

    func upload(_ record: SessionRecord) async throws {
        try await client.mutation("sessions:upsertSession", with: sessionArgs(record))

        let chunks = record.epochs.chunked(into: 60)
        for (i, chunk) in chunks.enumerated() {
            let epochs: [ConvexEncodable?] = chunk.map { epochArg($0) as ConvexEncodable? }
            try await client.mutation("sessions:upsertEpochChunk", with: [
                "clientId": record.id.uuidString,
                "chunkIndex": Double(i),
                "epochs": epochs as ConvexEncodable?,
                "isLast": (i == chunks.count - 1),
            ])
        }
    }

    // All numbers are sent as Double so they match Convex `v.number()` (float64), avoiding the
    // Swift-Int → Convex-int64 mismatch.
    private func sessionArgs(_ r: SessionRecord) -> [String: ConvexEncodable?] {
        var device: [String: ConvexEncodable?] = [
            "name": r.device.name,
            "sps": Double(r.device.sps),
            "firmware": r.device.firmware,
            "afeGain": r.device.afeGain,
        ]
        var baseline: [String: ConvexEncodable?]?
        if let b = r.baseline {
            baseline = [
                "engagement": b.engagement,
                "clench": b.clench,
                "frozenAt": b.frozenAt.timeIntervalSince1970 * 1000,
                "reused": b.reused,
            ]
        }
        return [
            "clientId": r.id.uuidString,
            "schemaVersion": Double(r.schema),
            "synthetic": r.synthetic,
            "syntheticNote": r.syntheticNote,
            "startedAt": r.startedAt.timeIntervalSince1970 * 1000,
            "endedAt": r.endedAt.timeIntervalSince1970 * 1000,
            "device": device as ConvexEncodable?,
            "baseline": baseline as ConvexEncodable?,
            "coverage": r.coverage,
            "epochCount": Double(r.epochs.count),
        ]
    }

    private func epochArg(_ e: Epoch) -> [String: ConvexEncodable?] {
        let bands: [String: ConvexEncodable?] = e.bands.mapValues { $0 as ConvexEncodable? }
        return [
            "t": e.t,
            "focus": e.focus,       // Double? → null when withheld
            "calm": e.calm,
            "clench": e.clench,
            "engagement": e.engagement,
            "bands": bands as ConvexEncodable?,
            "alphaPeak": e.alphaPeak,
            "rmsUv": e.rmsUv,
            "signalOk": e.signalOk,
            "fsOk": e.fsOk,
            "calibrating": e.calibrating,
            "state": e.state.rawValue,
        ]
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
