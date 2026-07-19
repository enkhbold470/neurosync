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

import AppKit
import Foundation

enum CloudConfig {
    /// The bundled public config, from the asset catalog (`CloudConfig` data set → `Assets.car`),
    /// loaded once. Both values here are public-safe; no secret ships in the app. Empty if absent.
    /// The asset catalog is the reliable bundling path here — loose files under the synchronized
    /// group are NOT copied into the app, only compiled sources and the asset catalog are.
    private static let bundled: [String: String] = {
        guard let asset = NSDataAsset(name: "CloudConfig"),
              let obj = try? JSONSerialization.jsonObject(with: asset.data),
              let dict = obj as? [String: Any]
        else { return [:] }
        return dict.compactMapValues { $0 as? String }
    }()

    /// Read a config value: bundled asset → Info.plist → environment. First non-empty wins.
    private static func value(_ key: String) -> String? {
        if let s = bundled[key], !s.isEmpty { return s }
        if let s = Bundle.main.object(forInfoDictionaryKey: key) as? String, !s.isEmpty { return s }
        if let s = ProcessInfo.processInfo.environment[key], !s.isEmpty { return s }
        return nil
    }

    /// The NeuroSync deployment URL (its OWN deployment — never `avid-guineapig-274`). From
    /// `CloudConfig.plist`, Info.plist, or the environment. `nil` → cloud sync is disabled.
    static var convexURL: URL? {
        guard let s = value("CONVEX_URL") else { return nil }
        return URL(string: s)
    }

    /// Clerk publishable key (public — safe to ship). From `CloudConfig.plist`, Info.plist, or env.
    /// `nil`/empty → Clerk is not configured and cloud sign-in is unavailable.
    static var clerkPublishableKey: String? { value("CLERK_PUBLISHABLE_KEY") }

    /// PostHog project API key (public `phc_`, client-side by design). `nil` → error tracking is off.
    static var posthogKey: String? { value("POSTHOG_KEY") }

    /// PostHog ingestion host. Defaults to US cloud.
    static var posthogHost: String { value("POSTHOG_HOST") ?? "https://us.i.posthog.com" }

    /// True when running inside the XCTest/Swift Testing host. The unit-test host launches the real
    /// app binary; if the app's Info.plist carries a CONVEX_URL + Clerk key, `canOfferSync` would be
    /// true and the app would touch `Clerk.shared` at launch, which traps under the test host. So the
    /// cloud is forced OFF during tests — they exercise the local-first path, which is the invariant.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Cloud sync only runs when a deployment is configured AND the user has opted in by signing in.
    /// Absent either, the app is fully local-first with no network use. Always off under tests.
    static var isConfigured: Bool { !isRunningTests && convexURL != nil }

    /// Both a deployment URL and a Clerk key are needed to offer sign-in + sync. Always off under tests.
    static var canOfferSync: Bool { !isRunningTests && convexURL != nil && clerkPublishableKey != nil }
}
