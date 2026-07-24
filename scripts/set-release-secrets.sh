#!/usr/bin/env bash
#
# NeuroSync — populate the five GitHub Actions secrets that release.yml needs.
#
# Run this when the release workflow fails at "Import Developer ID certificate" (an empty or
# truncated DEVELOPER_ID_CERT_P12_BASE64 is the usual cause) or after the yearly cert renewal.
#
# It exports the Developer ID Application identity from your login keychain — macOS will pop a
# keychain dialog asking you to allow it, which is why this cannot run unattended from an agent.
# Everything it writes lands in a mktemp dir that is deleted on exit, success or failure.
#
# PREREQS
#   - `gh auth status` is green and you have admin on enkhbold470/neurosync
#   - the Developer ID cert is in your login keychain (see scripts/release.sh)
#   - the notary .p8 is at the repo root (gitignored)
#
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="24QC7XFXVJ"
CERT_SHA1="D459F2343D987A24F8C60E14AB07BB7272A16A28"   # Developer ID Application: Enkhbold Ganbold
NOTARY_KEY_ID="${NOTARY_KEY_ID:-ZA42ZADL45}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-ddfce35f-097d-4fda-b7d9-83a5f9d78a0e}"
P8="${P8:-AuthKey_${NOTARY_KEY_ID}.p8}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v gh >/dev/null || { echo "✗ gh CLI not found"; exit 1; }
[ -f "$P8" ] || { echo "✗ notary key not found at $P8 (set P8=/path/to/AuthKey_*.p8)"; exit 1; }

echo "▸ Confirming the identity is in the login keychain"
security find-identity -v -p codesigning | grep -q "$CERT_SHA1" \
  || { echo "✗ no Developer ID Application ($CERT_SHA1) — renew it in Xcode ▸ Settings ▸ Accounts"; exit 1; }

# A throwaway password: the .p12 exists for ~2 seconds and only ever travels to the encrypted
# secrets store, so it never needs to be memorable — but it must match what CI is told.
P12_PW="$(uuidgen)"

echo "▸ Exporting the identity (macOS will ask you to allow keychain access — click Allow)"
# `security export` takes the whole keychain's identities, so the .p12 also carries the Apple
# Development / Apple Distribution keys. Repack with openssl so only the Developer ID identity
# reaches GitHub — a CI secret should hold exactly the one key the job needs.
security export -k "$HOME/Library/Keychains/login.keychain-db" \
  -t identities -f pkcs12 -P "$P12_PW" -o "$TMP/all.p12"

OSSL="$(command -v /opt/homebrew/bin/openssl || command -v openssl)"
"$OSSL" pkcs12 -in "$TMP/all.p12" -passin pass:"$P12_PW" -nodes -legacy > "$TMP/all.pem" 2>/dev/null \
  || "$OSSL" pkcs12 -in "$TMP/all.p12" -passin pass:"$P12_PW" -nodes > "$TMP/all.pem"

echo "▸ Selecting the Developer ID Application cert and its matching key"
# Split the bundle into one file per PEM block, then pair the leaf to its key by RSA modulus —
# friendlyName ordering in a .p12 is not something to trust.
mkdir -p "$TMP/parts"
awk -v d="$TMP/parts" '
  /^-----BEGIN/ { n++; f = sprintf("%s/blk%02d.pem", d, n) }
  f { print > f }
  /^-----END/   { close(f); f = "" }
' "$TMP/all.pem"

LEAF=""; KEY=""
for f in "$TMP/parts"/*.pem; do
  if grep -q "BEGIN CERTIFICATE" "$f"; then
    subj=$("$OSSL" x509 -noout -subject -in "$f" 2>/dev/null || true)
    case "$subj" in
      *"Developer ID Application"*"$TEAM_ID"*) LEAF="$f"; LEAF_MOD=$("$OSSL" x509 -noout -modulus -in "$f") ;;
      *"Developer ID Certification Authority"*|*"Apple Root CA"*) CHAIN="${CHAIN:-} $f" ;;
    esac
  fi
done
[ -n "$LEAF" ] || { echo "✗ no Developer ID Application cert for team $TEAM_ID in the export"; exit 1; }

for f in "$TMP/parts"/*.pem; do
  grep -q "PRIVATE KEY" "$f" || continue
  if [ "$("$OSSL" rsa -noout -modulus -in "$f" 2>/dev/null || true)" = "$LEAF_MOD" ]; then KEY="$f"; break; fi
done
[ -n "$KEY" ] || { echo "✗ found the cert but not its private key — export the identity, not the certificate"; exit 1; }

cat "$KEY" "$LEAF" ${CHAIN:-} > "$TMP/pick.pem"

# -legacy (RC2-40/3DES) because the runner validates with the system LibreSSL, which chokes on
# OpenSSL 3's default AES-256/PBKDF2 .p12. `security import` accepts either.
"$OSSL" pkcs12 -export -legacy -in "$TMP/pick.pem" -out "$TMP/devid.p12" -passout pass:"$P12_PW" \
  -name "Developer ID Application: Enkhbold Ganbold ($TEAM_ID)"

echo "▸ Verifying the .p12 exactly as CI will"
/usr/bin/openssl pkcs12 -in "$TMP/devid.p12" -nokeys -passin pass:"$P12_PW" > "$TMP/certs.pem"
grep -q "Developer ID Application" "$TMP/certs.pem" \
  || { echo "✗ repacked .p12 has no Developer ID Application cert"; exit 1; }
echo "  $(wc -c < "$TMP/devid.p12" | tr -d ' ') bytes, opens with the password, right identity ✓"

echo "▸ Setting secrets on enkhbold470/neurosync"
base64 < "$TMP/devid.p12" | tr -d '\n' | gh secret set DEVELOPER_ID_CERT_P12_BASE64
printf '%s' "$P12_PW"                  | gh secret set DEVELOPER_ID_CERT_PASSWORD
base64 < "$P8"           | tr -d '\n' | gh secret set NOTARY_KEY_P8_BASE64
printf '%s' "$NOTARY_KEY_ID"           | gh secret set NOTARY_KEY_ID
printf '%s' "$NOTARY_ISSUER_ID"        | gh secret set NOTARY_ISSUER_ID

echo
gh secret list
echo
echo "✓ Done. Re-run the release:  gh workflow run release.yml   (or push a v* tag)"
