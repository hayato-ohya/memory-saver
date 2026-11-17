#!/bin/bash
# Creates a self-signed code-signing certificate "MemorySaver Dev" in the login keychain. Run once.
#
# macOS identifies a login item by the app's code signature. An ad hoc signature changes with
# every build, so Open at login stops working after each rebuild or update. Signing every build
# with this one certificate keeps the signature's identity the same.
set -euo pipefail
NAME="MemorySaver Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Certificate '$NAME' already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
openssl pkcs12 -export -legacy -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:tmp
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P tmp -T /usr/bin/codesign -T /usr/bin/security
# Trust it for code signing. macOS asks for your password here.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
echo
security find-identity -v -p codesigning | grep "\"$NAME\"" && echo "Done. Now run: ./scripts/bundle.sh install"
