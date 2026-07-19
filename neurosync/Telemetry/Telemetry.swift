//
//  Telemetry.swift
//  neurosync
//
//  Production error + crash tracking via PostHog. This is a CRASH REPORTER, not analytics.
//
//  ── THE PRIVACY BOUNDARY (this app is local-first: "your data is yours, on your machine") ──
//
//  What this MAY send:  uncaught crashes, Swift errors, and short TECHNICAL diagnostics — a
//                       subsystem name, an error's description, the app/OS version. Enough to fix a
//                       bug, nothing more.
//  What this must NEVER send:  brain data of any kind (focus/calm/clench scores, engagement, band
//                       powers, epochs, waveforms), session content, activity/app context, calendar
//                       data, markers, or ANY personally-identifying information. We do not identify
//                       the PostHog person, so events are anonymous. Behavioural analytics (screen
//                       views, lifecycle, autocapture, session replay) are OFF.
//
//  Callers are responsible for keeping `context`/props technical. If you are tempted to attach a
//  focus score or a session to an event to "help debugging" — that is exactly what this boundary
//  forbids. Reproduce it locally instead.
//
//  Off entirely when no POSTHOG_KEY is configured (no network), and under the test host.
//

import Foundation
#if canImport(PostHog)
import PostHog
#endif

enum Telemetry {
    private static var enabled = false

    /// Configure error tracking once, at launch. No-op without a key or under tests.
    static func start() {
        guard !CloudConfig.isRunningTests, let key = CloudConfig.posthogKey, !key.isEmpty else { return }
        #if canImport(PostHog)
        let config = PostHogConfig(apiKey: key, host: CloudConfig.posthogHost)
        // Crash reporter, NOT analytics — turn behavioural capture off. Person profiles stay
        // identified-only, and since we never call `identify`, no person is ever created.
        config.captureApplicationLifecycleEvents = false
        config.personProfiles = .identifiedOnly
        PostHogSDK.shared.setup(config)
        enabled = true
        installUncaughtHandler()
        event("app_started", ["os": osVersion, "app_version": appVersion])
        #endif
    }

    /// Report a caught Swift error with a short technical context. Never pass brain data or PII.
    static func error(_ error: Error, _ context: String? = nil) {
        #if canImport(PostHog)
        guard enabled else { return }
        PostHogSDK.shared.captureException(error)
        if let context, !context.isEmpty {
            PostHogSDK.shared.capture("app_error", properties: ["context": context])
        }
        #endif
    }

    /// A technical diagnostic breadcrumb (e.g. "ble_connect_failed"). TECHNICAL fields only.
    static func event(_ name: String, _ props: [String: Any] = [:]) {
        #if canImport(PostHog)
        guard enabled else { return }
        PostHogSDK.shared.capture(name, properties: props)
        #endif
    }

    // MARK: - Internals

    private static func installUncaughtHandler() {
        #if canImport(PostHog)
        NSSetUncaughtExceptionHandler { ex in
            PostHogSDK.shared.capture("$exception", properties: [
                "$exception_list": [["type": ex.name.rawValue, "value": ex.reason ?? ""]],
                "context": "uncaught",
            ])
            PostHogSDK.shared.flush()
        }
        #endif
    }

    private static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
