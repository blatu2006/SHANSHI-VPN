#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Packaging/XcodeApp-Info.plist")
EXPORT_DIR="$PROJECT_DIR/dist/release-$VERSION"
PKG="$EXPORT_DIR/NLVC-VPN-$VERSION.pkg"
RELEASE_STATUS="$EXPORT_DIR/RELEASE-STATUS.txt"

PACKAGING_MODE=$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel' \
    "$PROJECT_DIR/Packaging/PacketTunnelSystemExtension-Info.plist" 2>/dev/null || true)
if [[ -z "$PACKAGING_MODE" ]]; then
    echo "ERROR: Direct Developer ID distribution requires the Packet Tunnel System Extension target." >&2
    exit 20
fi

: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to an xcrun notarytool keychain profile}"
: "${DOWNLOAD_URL:?Set DOWNLOAD_URL to the final HTTPS URL for the PKG}"
: "${UPDATE_MANIFEST_URL:?Set UPDATE_MANIFEST_URL to the HTTPS update.json URL}"

for RELEASE_URL in "$DOWNLOAD_URL" "$UPDATE_MANIFEST_URL"; do
    [[ "$RELEASE_URL" == https://* ]] || {
        echo "Release URLs must use HTTPS: $RELEASE_URL" >&2
        exit 1
    }
done

mkdir -p "$EXPORT_DIR"
NLVC_UPDATE_MANIFEST_URL="$UPDATE_MANIFEST_URL" \
    "$PROJECT_DIR/scripts/build_developer_id_pkg.command"
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
spctl --assess --type install --verbose=2 "$PKG"

SHA256=$(shasum -a 256 "$PKG" | awk '{print $1}')
/usr/bin/printf '%s\n' \
    'STATUS=READY' \
    "PKG=$PKG" \
    "SHA256=$SHA256" \
    > "$RELEASE_STATUS"
/usr/bin/printf '%s\n' \
    "{\"version\":\"$VERSION\",\"downloadURL\":\"$DOWNLOAD_URL\",\"sha256\":\"$SHA256\"}" \
    > "$EXPORT_DIR/update.json"
echo "Release: $PKG"
echo "Manifest: $EXPORT_DIR/update.json"
