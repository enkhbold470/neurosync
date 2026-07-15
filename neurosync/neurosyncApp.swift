//
//  neurosyncApp.swift
//  neurosync
//

import SwiftUI

/// The real entry point.
///
/// `--generate-synthetic` has to be handled BEFORE SwiftUI touches anything. Doing it inside
/// `App.init()` does not work: by then AppKit is already bootstrapping, `exit()` races the run loop,
/// and the app can come up as a GUI anyway (the unit-test host launches this same binary, which made
/// the failure obvious). A plain `@main enum` runs first, so the CLI path generates and exits before
/// `NSApplication` ever exists.
@main
enum Entry {
    static func main() {
        if SyntheticCLI.requested {
            SyntheticCLI.run()   // generates, prints, and exit()s — never returns
        }
        NeuroSyncApp.main()
    }
}

struct NeuroSyncApp: App {
    /// One model, shared by the window and the menu bar. They must never disagree about what
    /// the brain is doing.
    @State private var model = VertexModel()

    /// The Day view's state. Deliberately SEPARATE from `model`: the menu bar reads `model` and only
    /// `model`, so persisted data — synthetic or otherwise — has no path to the ambient readout.
    /// See `menuBarNeverReadsPersistedData`.
    @State private var days = DayModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, days: days)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
