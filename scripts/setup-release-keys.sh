#!/bin/bash
# One-time setup for the maintainer: the keys GitHub Actions needs to publish releases.
#
#  - "Deckhand Release Signing": a self-signed code signing identity. Releases are signed with it so macOS
#    keeps permissions (Accessibility, Screen Recording) when Deckhand updates itself: they belong to the
#    signature, and an ad-hoc signature changes with every build.
#  - An Ed25519 key for updates. The updater accepts only archives signed with it; the public half is
#    in Sources/Deckhand/Features/Updates/UpdateKey.swift.
#
# Both go into the login keychain (the backup) and into the repository's Actions secrets
# RELEASE_P12, RELEASE_P12_PASSWORD and UPDATE_KEY. Nothing is printed or left on disk.
# Needs gh logged in with admin rights on the repository. Refuses to run twice.

set -euo pipefail
REPO="${REPO:-NNA1618/deckhand}"
NAME="Deckhand Release Signing"
KEY_SERVICE="Deckhand update signing key"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
cd "$(dirname "$0")/.."

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "error: \"$NAME\" already exists; delete it first to rotate"; exit 1
fi
if security find-generic-password -s "$KEY_SERVICE" >/dev/null 2>&1; then
    echo "error: the update key already exists; delete it first to rotate"; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(uuidgen)"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = NNA1618
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

read -r PRIV PUB < <(swift scripts/update-key.swift generate)
security add-generic-password -s "$KEY_SERVICE" -a deckhand -w "$PRIV" "$KEYCHAIN"

base64 -i "$TMP/identity.p12" | gh secret set RELEASE_P12 --repo "$REPO"
printf '%s' "$PASS" | gh secret set RELEASE_P12_PASSWORD --repo "$REPO"
printf '%s' "$PRIV" | gh secret set UPDATE_KEY --repo "$REPO"

echo "==> created \"$NAME\" and the update key; secrets set on $REPO"
echo "==> public update key: $PUB"
