#!/bin/bash
# Creates a self-signed code-signing certificate in the login keychain so build.sh can sign with a
# stable identity. macOS then keeps the Accessibility/Camera grants across rebuilds.
# Run once:  ./make-signing-cert.sh      (may show one keychain password dialog; choose "Always Allow")
set -euo pipefail
NAME="${SIGN_IDENTITY:-Zaryab Local Code Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Identity \"$NAME\" already exists."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
subjectKeyIdentifier=hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:temp -legacy 2>/dev/null \
    || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:temp
security import "$TMP/id.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign -T /usr/bin/security
# Trust it for code signing (user-level trust only; may prompt for your login password).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Created \"$NAME\". Run ./build.sh run, then grant Accessibility one last time."
else
    echo "Certificate imported but not yet listed as valid. Open Keychain Access, find \"$NAME\", and set Code Signing trust to Always Trust."
fi
