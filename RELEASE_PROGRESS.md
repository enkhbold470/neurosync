# NeuroSync — Ship & CI/CD progress

_Working checkpoint · last updated 2026-07-20._
_Local status note. Contains **no private keys or secrets** — safe to keep, safe to delete. Not auto-committed._

## ✅ Done

### App is shipped (notarized DMG)
- `build/release/neurosync.dmg` — Developer ID signed, **notarized + stapled**, Gatekeeper-accepted.
- v1.0 (build 1), `com.inkyg.neurosync`, Hardened Runtime on, team **24QC7XFXVJ**.
- Build it any time with `./scripts/release.sh` (archive → export → notarize → staple → DMG).
- 93 unit tests green.

### Notarization now uses an App Store Connect API key
- Team Key **`ZA42ZADL45`** (Access: Admin), team 24QC7XFXVJ, issuer stored in the `NOTARY_ISSUER_ID` secret.
- Key file `AuthKey_ZA42ZADL45.p8` is in the repo root, **gitignored**, and stored in the Keychain
  under the `neurosync-notary` profile (Apple-validated; replaced the old app-specific-password creds).

### CI is live on `main` (public repo `enkhbold470/neurosync`)
- `.github/workflows/ci.yml` (PR #9, merged):
  - **secret-guard** (ubuntu) — fails if a signing key / provider secret is ever committed.
  - **build-test** (macos-latest) — builds + runs `neurosyncTests`, ad-hoc signed. GitHub's
    `macos-latest` has **macOS 26.4 / Xcode 26.6**, so the 26.1 target builds fine in CI.
- Both green on every push/PR.

### Release pipeline exists on `main`
- `.github/workflows/release.yml` (PR #10, merged): on a `v*` tag / manual dispatch —
  archive → Developer ID sign → notarize (API key) → staple → DMG → attach to a GitHub Release.
  Ephemeral keychain, first-party actions + `gh` only.
- Secrets documented in `.github/workflows/README.md`.

### Secret hygiene
- `.gitignore`: `*.p8`, `AuthKey_*.p8`, `*.p12`, `*.cer`, `*.mobileprovision` — none tracked.

## 🔧 In progress — arming the release pipeline

The release workflow is being validated by a **dry-run dispatch** (builds + signs + notarizes, no
release created). Two dry-runs so far both failed at **Import Developer ID certificate**:

1. Run `29680920777` → `SecKeychainItemImport: invalid parameters`.
2. Run `29681079757` (hardened, self-diagnosing import step) → root cause found:
   **`DEVELOPER_ID_CERT_P12_BASE64` decodes to 0 bytes — the secret is EMPTY.**
   It was set from `base64 -i DeveloperID.p12`, which had failed (`No such file or directory`);
   the empty output got stored as the secret.

The real cert **is** on disk and valid: `/Users/inky/Desktop/neurofocus-brain/Certificates.p12`
(valid PKCS#12, ~15 KB).

Fix in flight on branch **`ci/fix-release-cert-import`**: the import step now strips whitespace
before decoding (wrapping-proof), validates the `.p12` opens with the password, prints the cert
subject, and fails loudly if there's no *Developer ID Application* identity.

### Secrets status
| Secret | State |
|---|---|
| `NOTARY_KEY_ID` | ✅ set |
| `NOTARY_ISSUER_ID` | ✅ set |
| `NOTARY_KEY_P8_BASE64` | ✅ set |
| `DEVELOPER_ID_CERT_PASSWORD` | ⚠️ set — confirm it matches `Certificates.p12` |
| `DEVELOPER_ID_CERT_P12_BASE64` | ❌ **empty — must re-set** |

## ⏭ Next steps (owner runs these — `gh secret set` is blocked for the agent)

1. Re-set the cert secret from the real file:
   ```bash
   base64 -i /Users/inky/Desktop/neurofocus-brain/Certificates.p12 | gh secret set DEVELOPER_ID_CERT_P12_BASE64
   ```
2. Confirm the password matches that file (re-set if unsure):
   ```bash
   gh secret set DEVELOPER_ID_CERT_PASSWORD   # paste Certificates.p12's password
   ```
   Optional local check (prints only the public subject — want `CN=Developer ID Application: … (24QC7XFXVJ)`):
   ```bash
   openssl pkcs12 -in /Users/inky/Desktop/neurofocus-brain/Certificates.p12 -nokeys -passin pass:'YOURPASS' | openssl x509 -noout -subject
   ```
3. Re-dispatch the hardened release dry-run and watch it:
   ```bash
   gh workflow run release.yml --ref ci/fix-release-cert-import
   ```
4. When green → merge the fix branch to `main`, then cut the first real release:
   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```

## 🧹 Housekeeping / optional
- **Revoke** the app-specific password shared in chat earlier (account.apple.com → Sign-In and
  Security) — it's unused (notary is on the API key) and was exposed in plaintext.
- Keep `Certificates.p12` somewhere safe or delete it (the secret is now in GitHub).
- Cloud sync ships on **dev** Clerk + Convex backends; promote to prod later per `CLOUD_SETUP.md`.
- `SHIPPING.md`'s "Current state (audited)" section is stale (it predates the working cert + notary).
