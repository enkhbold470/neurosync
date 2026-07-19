//
//  CloudConfigTests.swift
//  neurosyncTests
//
//  Cloud is opt-in and local-first. These pin two things:
//   1. The public config asset actually ships in the bundle and parses — otherwise the app would
//      silently never offer sync. Both values here are PUBLIC-safe (publishable key + public URL).
//   2. Cloud is force-OFF under the test host. The unit-test host launches the real app binary; with
//      a CONVEX_URL + Clerk key configured, `canOfferSync` would be true and the app would touch
//      `Clerk.shared` at launch, which traps under the test host. The `isRunningTests` guard prevents
//      that, so tests always exercise the local-first path.
//

import Testing
import Foundation
import AppKit
@testable import neurosync

@Test func cloudConfigAssetBundlesAndParses() throws {
    let asset = try #require(NSDataAsset(name: "CloudConfig"), "CloudConfig data asset is not bundled")
    let dict = try #require(
        try JSONSerialization.jsonObject(with: asset.data) as? [String: Any],
        "CloudConfig.json is not a JSON object")

    let url = dict["CONVEX_URL"] as? String
    #expect(url?.hasPrefix("https://") == true)
    // It must be NeuroSync's OWN deployment, never the landing page's shared one.
    #expect(url?.contains("avid-guineapig-274") == false, "app must not point at the landing-page deployment")

    let key = dict["CLERK_PUBLISHABLE_KEY"] as? String
    #expect(key?.hasPrefix("pk_") == true)
}

@Test func cloudSyncIsForcedOffUnderTheTestHost() {
    // The whole point of the guard: even with keys configured, tests never light up the cloud path.
    #expect(CloudConfig.isRunningTests == true)
    #expect(CloudConfig.canOfferSync == false)
    #expect(CloudConfig.isConfigured == false)
}
