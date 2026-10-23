#!/bin/zsh
set -euo pipefail

KEYCHAIN="/Users/linlu/Library/Keychains/login.keychain-db"
CERTIFICATE_DIR="/Users/linlu/.apple-signing/nlvc-vpn"

import_certificate() {
    local certificate="$1"
    echo
    echo "Importing ${certificate:t} into the login keychain."
    echo "Enter the password used when this .p12 file was exported."
    security import "$certificate" \
        -k "$KEYCHAIN" \
        -t agg \
        -f pkcs12 \
        -T /usr/bin/codesign \
        -T /usr/bin/productbuild \
        -T /usr/bin/pkgbuild \
        -T /usr/bin/security
}

import_certificate "$CERTIFICATE_DIR/develop.p12"
import_certificate "$CERTIFICATE_DIR/Untitled.p12"

echo
echo "SIGNING_CERTIFICATE_IMPORT_RESULT=SUCCESS"
security find-identity -v -p codesigning
security find-identity -v -p basic | grep -E 'Developer ID (Application|Installer)|valid identities' || true
echo
read "REPLY?Press Return to close this window..."
