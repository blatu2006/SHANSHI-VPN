#!/bin/zsh
set -euo pipefail

SOURCE_APPLICATION="/Users/linlu/develop.p12"
SOURCE_INSTALLER="/Users/linlu/Untitled.p12"
DESTINATION="/Users/linlu/.apple-signing/nlvc-vpn"

for source_file in "$SOURCE_APPLICATION" "$SOURCE_INSTALLER"; do
    [[ -f "$source_file" ]] || {
        echo "ERROR: Certificate file not found: $source_file" >&2
        exit 2
    }
done

mkdir -p "$DESTINATION"
chmod 700 "/Users/linlu/.apple-signing" "$DESTINATION"
cp "$SOURCE_APPLICATION" "$DESTINATION/develop.p12"
cp "$SOURCE_INSTALLER" "$DESTINATION/Untitled.p12"
chmod 600 "$DESTINATION/develop.p12" "$DESTINATION/Untitled.p12"

echo "SIGNING_CERTIFICATE_COPY_RESULT=SUCCESS"
stat -f '%Sp %z %N' "$DESTINATION/develop.p12" "$DESTINATION/Untitled.p12"
