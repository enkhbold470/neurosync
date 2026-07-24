# CI / CD

Two workflows:

## `ci.yml` — on every push to `main` and every PR
- **secret-guard** (ubuntu): fails if a signing key (`*.p8/.p12/.cer/.mobileprovision`) or a
  provider secret (`BEGIN PRIVATE KEY`, `sk_live/test_…`, `CONVEX_DEPLOY_KEY=…`) is ever committed.
  This is a **public** repo — that guard is the seatbelt.
- **build-test** (macOS): logs the runner's macOS/Xcode/SDK, builds `neurosync`, runs
  `neurosyncTests` with ad-hoc signing (hosted runners have no Developer ID cert). No secrets needed.

## `release.yml` — on a `v*` tag (or manual dispatch)
Archives → signs (Developer ID) → notarizes → staples → builds a DMG → attaches it to the GitHub
Release. The API key is passed straight to `notarytool` (no keychain profile needed); the Developer ID
cert is imported into an ephemeral keychain that is deleted afterwards.

### Required repository secrets

**Just run `./scripts/set-release-secrets.sh`.** It exports the Developer ID identity from your
login keychain (macOS will ask you to allow it), repacks it so only that one key travels, verifies
the `.p12` the same way the runner does, and sets all five secrets. Re-run it after the yearly
cert renewal.

A release that dies at *"Decoded .p12: 0 bytes"* means the secret was stored empty — the job now
catches that in the **Preflight** step instead, and the fix is that script.

To do it by hand, add these under **Settings → Secrets and variables → Actions**:

| Secret | What it is | How to produce |
|---|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application cert **+ private key**, as base64 `.p12` | Keychain Access → export the "Developer ID Application: … (24QC7XFXVJ)" identity as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | the password you set on that `.p12` export | — |
| `NOTARY_KEY_P8_BASE64` | App Store Connect API key `.p8`, base64 | `base64 -i AuthKey_ZA42ZADL45.p8 \| pbcopy` |
| `NOTARY_KEY_ID` | the key id | `ZA42ZADL45` |
| `NOTARY_ISSUER_ID` | the issuer id | from App Store Connect → Integrations → API |

Team id (`24QC7XFXVJ`) is not secret and lives in the project/`ExportOptions.plist`.

> Never paste a `.p8`/`.p12`/password into a workflow file, a commit, or a PR — only into the
> encrypted Secrets store. `secret-guard` will fail the build if a key lands in the tree.
