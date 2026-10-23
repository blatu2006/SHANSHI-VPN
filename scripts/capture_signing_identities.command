#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT="$PROJECT_DIR/.build/signing-identities.log"

{
    echo "=== Code signing identities ==="
    security find-identity -v -p codesigning
    echo
    echo "=== All basic identities ==="
    security find-identity -v -p basic
} > "$OUTPUT" 2>&1

echo "SIGNING_IDENTITY_CAPTURE_RESULT=SUCCESS"
cat "$OUTPUT"
