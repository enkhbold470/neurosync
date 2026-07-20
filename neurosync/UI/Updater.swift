//
//  Updater.swift
//  neurosync
//
//  Sparkle auto-update for the direct-distributed (Developer ID + notarized) app. Reads SUFeedURL
//  and SUPublicEDKey from Info.plist; on launch it quietly checks the appcast and, when a newer
//  signed build is available, offers to install it. Unsigned/dev builds just log and no-op.
//

import SwiftUI
import Combine
import Sparkle

/// Wraps Sparkle's standard controller so SwiftUI can drive a "Check for Updates…" menu item and
/// disable it while the updater isn't ready.
final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller.updater.checkForUpdates() }
}

/// The menu command, dropped into the app menu next to "About".
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdaterModel
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
