#!/usr/bin/env bash
set -euo pipefail

# One-time setup: create a stable, self-signed code-signing identity for local
# PostRoll builds. Run this ONCE (you'll be asked for your login password to
# trust the certificate for code signing).
#
# Why: build-install.sh otherwise ad-hoc signs the app, which gives it a new
# code identity on every rebuild. macOS keys folder-permission grants
# (Downloads, Desktop, Documents) to the signing identity, so an ad-hoc build
# re-prompts for access you already granted after every rebuild. Signing with a
# stable certificate keeps the identity constant, so the grants persist.
#
# Usage: ./setup-signing.sh

IDENTITY="PostRoll Local Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "==> Identity '$IDENTITY' already exists. Nothing to do."
  exit 0
fi

echo "==> Creating self-signed code-signing certificate: $IDENTITY"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Config-file form (works with the system LibreSSL, which lacks -addext).
cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -new -x509 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/openssl.cnf" >/dev/null 2>&1

# `-legacy` (OpenSSL 3) forces 3DES/RC2 + SHA1-MAC encoding. Without it,
# OpenSSL 3 writes a SHA-256 MAC that Apple's `security import` can't verify and
# wrongly reports as "MAC verification failed (wrong password?)". Fall back to
# the plain form on LibreSSL/older OpenSSL, which don't accept `-legacy`.
openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:postroll -name "$IDENTITY" >/dev/null 2>&1 \
|| openssl pkcs12 -export \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:postroll -name "$IDENTITY" >/dev/null 2>&1

# Import the key+cert; allow codesign to use the private key without prompting.
security import "$TMP/identity.p12" -k "$LOGIN_KEYCHAIN" -P postroll \
  -T /usr/bin/codesign -A >/dev/null

echo "==> Trusting the certificate for code signing (enter your login password if prompted)"
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "==> Done. Rebuild with ./build-install.sh and it will sign with '$IDENTITY'."
  echo "    You'll grant folder access one more time, then it sticks across rebuilds."
else
  echo "Error: identity was not created. Check the output above." >&2
  exit 1
fi
