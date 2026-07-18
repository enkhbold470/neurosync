//
//  CloudConfig.swift
//  neurosync
//
//  Opt-in cloud sync configuration. The instrument is local-first: with no `CONVEX_URL` configured
//  and no signed-in user, everything here is inert and the app behaves exactly as it always has.
//
//  The app only ever needs the PUBLIC deployment URL. The Convex deploy key and any auth secrets
//  live in the gitignored `.env` and are used by the CLI at deploy time — they never enter the app
//  binary. See ../../CLOUD_SETUP.md.
//

import Foundation

enum CloudConfig {
    /// The NeuroSync deployment URL (its OWN deployment — never `avid-guineapig-274`). Read from the
    /// Info.plist key `CONVEX_URL` (wire it to a build setting), or the environment for dev runs.
    /// `nil` → cloud sync is disabled.
    static var convexURL: URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "CONVEX_URL") as? String,
           !s.isEmpty, let u = URL(string: s) {
            return u
        }
        if let s = ProcessInfo.processInfo.environment["CONVEX_URL"], !s.isEmpty {
            return URL(string: s)
        }
        return nil
    }

    /// Cloud sync only runs when a deployment is configured AND the user has opted in by signing in.
    /// Absent either, the app is fully local-first with no network use.
    static var isConfigured: Bool { convexURL != nil }
}
