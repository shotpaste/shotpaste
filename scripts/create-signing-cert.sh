#!/usr/bin/env bash
# create-signing-cert.sh — Create a local development code-signing identity.
#
# This script never creates or exports official release credentials. Published
# releases use the existing identity with SHA-1 fingerprint
# 35517841F1D32EC1ED7D1F411565845C4AA4B70A documented in docs/DEVELOPMENT.md.
# Do not recreate or replace that identity.
#
# Usage: ./scripts/create-signing-cert.sh [cert-name] [validity-days]
#
# This script:
#   1. Creates a temporary keychain
#   2. Generates a local self-signed "Code Signing" certificate
#   3. Imports the identity into the login keychain
#   4. Deletes all temporary key and PKCS#12 files

set -euo pipefail

CERT_NAME="${1:-ShotPaste Local Development}"
VALIDITY_DAYS="${2:-3650}"  # 10 years default

if [[ "$CERT_NAME" == "ShotPaste Self-Signed" || "$CERT_NAME" == "ShotPaste Release" ]]; then
  echo "Error: '$CERT_NAME' is reserved for release-signing use." >&2
  echo "Use the default local identity or choose another development-only name." >&2
  exit 1
fi

if [[ ! "$VALIDITY_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: validity-days must be a positive integer." >&2
  exit 1
fi

if security find-identity -v -p codesigning | grep -Fq "\"$CERT_NAME\""; then
  echo "Local code-signing identity '$CERT_NAME' already exists; keeping it unchanged."
  exit 0
fi

TEMP_DIR=$(mktemp -d)
KEYCHAIN_PATH="$TEMP_DIR/signing.keychain-db"
KEYCHAIN_PASSWORD=$(uuidgen)
P12_PATH="$TEMP_DIR/signing-cert.p12"
P12_PASSWORD=$(uuidgen)
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
  [[ -n "$keychain" ]] && ORIGINAL_KEYCHAINS+=("$keychain")
done < <(
  security list-keychains -d user \
    | sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/'
)

cleanup() {
  if [[ "${#ORIGINAL_KEYCHAINS[@]}" -gt 0 ]]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" 2>/dev/null || true
  fi
  security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "=== ShotPaste Local Development Certificate ==="
echo ""
echo "Certificate name: $CERT_NAME"
echo "Validity: $VALIDITY_DAYS days"
echo ""

# 1. Create temporary keychain
echo "→ Creating temporary keychain..."
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
if [[ "${#ORIGINAL_KEYCHAINS[@]}" -gt 0 ]]; then
  security list-keychains -d user -s "$KEYCHAIN_PATH" "${ORIGINAL_KEYCHAINS[@]}"
else
  security list-keychains -d user -s "$KEYCHAIN_PATH"
fi

# 2. Generate self-signed certificate using certutil
echo "→ Generating self-signed code signing certificate..."

# Create certificate signing request config
cat > "$TEMP_DIR/cert.cfg" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
prompt             = no
x509_extensions    = codesign

[ req_dn ]
CN = $CERT_NAME
O  = ShotPaste

[ codesign ]
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# Generate key and self-signed certificate
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TEMP_DIR/key.pem" \
  -out "$TEMP_DIR/cert.pem" \
  -days "$VALIDITY_DAYS" \
  -config "$TEMP_DIR/cert.cfg" \
  2>/dev/null

# 3. Create a temporary P12 for login-keychain import. OpenSSL 3 defaults to
# PBES2/AES, which macOS security import can reject with a misleading "wrong
# password" error. Use its legacy
# PKCS#12 encoding when available; Apple LibreSSL already emits a compatible P12.
P12_EXPORT_ARGS=(
  -export
  -out "$P12_PATH"
  -inkey "$TEMP_DIR/key.pem"
  -in "$TEMP_DIR/cert.pem"
  -passout "pass:$P12_PASSWORD"
)
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
  P12_EXPORT_ARGS+=(-legacy)
fi
openssl pkcs12 "${P12_EXPORT_ARGS[@]}" 2>/dev/null

# 4. Import into the login keychain (persists for local builds & testing)
echo "→ Importing certificate into login keychain..."
security import "$P12_PATH" -P "$P12_PASSWORD" \
  -A -t cert -f pkcs12 -T /usr/bin/codesign \
  -k "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
  || security import "$P12_PATH" -P "$P12_PASSWORD" \
    -A -t cert -f pkcs12 -T /usr/bin/codesign \
    -k "$HOME/Library/Keychains/login.keychain" 2>/dev/null \
  || {
    echo "Error: could not import the local identity into the login keychain." >&2
    exit 1
  }

# Trust the certificate for code signing (avoids manual Keychain Access step)
echo "→ Trusting certificate for code signing..."
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$TEMP_DIR/cert.pem" 2>/dev/null \
  || security add-trusted-cert -d -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain" "$TEMP_DIR/cert.pem" 2>/dev/null \
  || echo "⚠️  Could not auto-trust. Trust manually in Keychain Access."

# Verify the identity is available for code signing
echo ""
echo "→ Verifying certificate in login keychain..."
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "✅ Certificate '$CERT_NAME' is available for code signing"
else
  echo "Error: certificate was imported but is not a valid code-signing identity." >&2
  echo "Trust it manually in Keychain Access, then run the build again:" >&2
  echo "  1. Open Keychain Access" >&2
  echo "  2. Find '$CERT_NAME'" >&2
  echo "  3. Double-click → Trust → Code Signing → Always Trust" >&2
  echo ""
  echo "Available signing identities:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

echo ""
echo "============================================"
echo "✅ Local development identity is ready."
echo "============================================"
echo ""
echo "Certificate name for codesign: \"$CERT_NAME\""
echo "Valid for: $VALIDITY_DAYS days"
echo "Temporary private-key and P12 files will be deleted on exit."
echo "This identity is for local builds only; it is not a release credential."
echo "============================================"
