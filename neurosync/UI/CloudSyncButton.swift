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
                .sheet(isPresented: $showAuth) { AuthSheet { showAuth = false } }
            }
        }
    }

    /// Clerk's `AuthView` is built for iPhone widths; dropped into a 360pt sheet on macOS it overflows
    /// and clips the email field and buttons. Give it a comfortable fixed frame and our own Close, so
    /// the whole card is visible and dismissable.
    private struct AuthSheet: View {
        let onClose: () -> Void

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("SIGN IN TO SYNC")
                        .font(.data(10, .bold)).tracking(1.6)
                        .foregroundStyle(Ink.muted)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.dim)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)

                Divider().overlay(Ink.rule)

                AuthView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // ClerkKit's AuthView has a fixed minimum content width built for iPhone; at 460 it still
            // overflowed and clipped the email field + the "last used" chip on macOS. 620 clears it.
            .frame(width: 620, height: 740)
            .background(Ink.panel)
            // Match the app's accent so the sheet doesn't read as a stock white Clerk form.
            .environment(\.clerkTheme, ClerkTheme(
                colors: .init(primary: Ink.amber),
                design: .init(borderRadius: 12)))
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
