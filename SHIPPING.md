# Shipping NeuroSync

**NeuroSync is a macOS app** (CoreBluetooth instrument, deployment target macOS 26.1). There is **no
iOS target** — "iOS certification" doesn't apply. For a Mac app you distribute yourself (not via the
Mac App Store, which you said you don't need), "certification" means **Developer ID signing + Apple
notarization**, producing a `.dmg` any Mac will open without Gatekeeper warnings. `scripts/release.sh`
does the whole pipeline in one command.

## Current state (audited)
- ✅ Hardened Runtime is ON, App Sandbox on, entitlements are minimal + justified (Bluetooth, network
  client for sync, Calendar read, user-selected files).
- ✅ Team ID `24QC7XFXVJ`, bundle id `com.inkyg.neurosync`, version 1.0 (1).
- ⚠️ **The only signing cert in your keychain is "Apple Development" — and it's for a *different* team
  (`79RF34SL3K`), not the project's `24QC7XFXVJ`.** There is **no "Developer ID Application"** cert
  (needed to notarize for direct distribution). Resolve the team first (below).
- ⚠️ No notary credentials stored yet.

## The 3 human steps Claude can't do (Apple requires you)
1. **Confirm the team.** Decide whether the app ships under `24QC7XFXVJ` or `79RF34SL3K`, then in
   **Xcode ▸ Settings ▸ Accounts** sign in with the Apple ID that owns that team and set the project's
   `DEVELOPMENT_TEAM` to match. (If they should be the same team, fix whichever is wrong.)
2. **Create the Developer ID Application certificate** for that team: Xcode ▸ Settings ▸ Accounts ▸
   Manage Certificates ▸ **+** ▸ *Developer ID Application*. Confirm with
   `security find-identity -v -p codesigning` (you should see a "Developer ID Application: … (TEAM)").
3. **Store notary credentials once** (this is the single credentials pause):
   ```bash
   xcrun notarytool store-credentials neurosync-notary \
     --apple-id "<you@apple.id>" --team-id 24QC7XFXVJ --password "<app-specific-password>"
   ```
   Get an app-specific password at account.apple.com ▸ Sign-In and Security, or use an App Store
   Connect API key (`--key`/`--key-id`/`--issuer`).

## Then ship
```bash
./scripts/release.sh          # archive → export → notarize → staple → signed, notarized DMG
```
Output: `build/release/neurosync.dmg`, notarized + stapled, verified with `spctl`/`stapler`.

## If you DO want the Mac App Store later
Change `dist/ExportOptions.plist` `method` to `app-store-connect`, create an **Apple Distribution**
cert, and upload with `xcrun altool --upload-app` / Transporter. (Not needed per your note.)

## The "publish via Chrome" ask
The Apple Developer portal / App Store Connect steps are behind your Apple login, which I can't drive
without your credentials. Once you're signed in to Chrome on developer.apple.com, I can drive specific
pages (e.g. registering the app, creating a cert, filling submission metadata) with browser automation
— just say which step and confirm you're logged in.
