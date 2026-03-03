#!/bin/bash
# Creates a self-signed "Hearsay Dev" code signing certificate.
# Run once — the cert persists in your login keychain for 10 years.
# This gives a stable signing identity so macOS TCC permissions
# (Microphone, Screen Recording) survive across rebuilds.

set -euo pipefail

CERT_NAME="Hearsay Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Check if already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ Certificate '$CERT_NAME' already exists."
    security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME"
    exit 0
fi

echo "Creating self-signed certificate '$CERT_NAME'..."

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Generate certificate config
cat > "$TMPDIR/cert.cfg" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
prompt             = no
[ req_dn ]
CN = $CERT_NAME
[ extensions ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF

# Generate key + self-signed cert (valid 10 years)
openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" \
    -days 3650 -nodes \
    -config "$TMPDIR/cert.cfg" -extensions extensions 2>/dev/null

# Package as p12 for keychain import
openssl pkcs12 -export \
    -out "$TMPDIR/cert.p12" \
    -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" \
    -passout pass:tmp -legacy 2>/dev/null

# Import into login keychain
security import "$TMPDIR/cert.p12" -k "$KEYCHAIN" \
    -T /usr/bin/codesign -P "tmp"

# Trust for code signing
security add-trusted-cert -d -r trustRoot -p codeSign \
    -k "$KEYCHAIN" "$TMPDIR/cert.pem" 2>/dev/null

echo ""
echo "✅ Certificate '$CERT_NAME' created and trusted."
security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME"
echo ""
echo "You may need to unlock the keychain if prompted during signing."
echo "Now run: ./run-dev.sh"
