//
//  neurosyncApp.swift
//  neurosync
//

import SwiftUI

@main
struct neurosyncApp: App {
    /// One model, shared by the window and the menu bar. They must never disagree about what
    /// the brain is doing.
    @State private var model = VertexModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
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
