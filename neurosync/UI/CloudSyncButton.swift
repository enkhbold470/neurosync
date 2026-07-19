//
//  CloudSyncButton.swift
//  neurosync
//
//  Sign-in + sync status in the header. Shown ONLY when a deployment URL and a Clerk key are both
//  configured — no account is ever required to use the instrument. Local-first stays the default.
//

import SwiftUI
import ClerkKit
import ClerkKitUI
import ConvexMobile

struct CloudSyncButton: View {
    var cloud: ConvexCloud
    @State private var showAuth = false

    var body: some View {
        if CloudConfig.canOfferSync {
            if cloud.signedIn {
                syncedChip
            } else {
                Button { showAuth = true } label: {
                    Label("Sign in to sync", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(InstrumentButton())
                .sheet(isPresented: $showAuth) { AuthView().frame(minWidth: 360, minHeight: 460) }
            }
        }
    }

    private var syncedChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.icloud").font(.system(size: 10, weight: .semibold))
            Text("SYNCED").font(.data(9, .semibold)).tracking(1.2)
            Button {
                Task { await cloud.client?.logout() }
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Sign out — stops cloud sync. Your local sessions are untouched.")
        }
        .foregroundStyle(Ink.amber)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Ink.amber.opacity(0.12), in: Capsule(style: .continuous))
        .help("Your real sessions are mirrored to the cloud. Local JSON stays the source of truth.")
    }
}
