#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DERIVED_DIR="$PROJECT_DIR/.build/xcode-release"
PRODUCT_APP="$DERIVED_DIR/Build/Products/Release/NLVC VPN.app"
OUTPUT_APP="$PROJECT_DIR/dist/NLVC VPN.app"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/dist" "$DERIVED_DIR"

SIGNING_ARGS=()
if [[ "${1:-}" == "--unsigned" ]]; then
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
fi

if xcodebuild \
    -project HillstoneConnect.xcodeproj \
    -scheme HillstoneConnect \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DIR" \
    -allowProvisioningUpdates \
    "${SIGNING_ARGS[@]}" \
    build; then
    :
else
    result=$?
    if [[ "${1:-}" != "--unsigned" ]]; then
        echo >&2
        echo "Signing diagnosis:" >&2
        "$PROJECT_DIR/scripts/check_apple_signing.command" --development || true
    fi
    exit "$result"
fi

# Always publish a clean bundle. Merging into a previous signed .app can keep
# stale files that no longer belong to the current code signature.
if [[ -d "$OUTPUT_APP" ]]; then
    /bin/rm -rf "$OUTPUT_APP"
fi
/usr/bin/ditto "$PRODUCT_APP" "$OUTPUT_APP"

PACKET_TUNNEL="$OUTPUT_APP/Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension"
if [[ ! -d "$PACKET_TUNNEL" ]]; then
    echo "ERROR: Embedded packet tunnel system extension is missing: $PACKET_TUNNEL" >&2
    exit 20
fi
if [[ -d "$OUTPUT_APP/Contents/PlugIns" ]]; then
    echo "ERROR: Stale App Extension content was included in the app bundle." >&2
    exit 21
fi
PROVIDER_CLASS=$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel' \
    "$PACKET_TUNNEL/Contents/Info.plist" 2>/dev/null || true)
if [[ -z "$PROVIDER_CLASS" ]]; then
    echo "ERROR: Packet tunnel System Extension has no provider class." >&2
    exit 22
fi
MACH_SERVICE=$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEMachServiceName' \
    "$PACKET_TUNNEL/Contents/Info.plist" 2>/dev/null || true)
if [[ "$MACH_SERVICE" != "T84BKD53ZD.com.linlu.hillstoneconnect."* ]]; then
    echo "ERROR: NEMachServiceName is not inside the NLVC VPN App Group." >&2
    exit 23
fi

if [[ "${1:-}" != "--unsigned" ]]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
    APP_ENTITLEMENTS_CHECK="$DERIVED_DIR/app-signed-entitlements.plist"
    EXTENSION_ENTITLEMENTS_CHECK="$DERIVED_DIR/extension-signed-entitlements.plist"
    /usr/bin/codesign -d --entitlements "$APP_ENTITLEMENTS_CHECK" --xml "$OUTPUT_APP" 2>/dev/null
    /usr/bin/codesign -d --entitlements "$EXTENSION_ENTITLEMENTS_CHECK" --xml "$PACKET_TUNNEL" 2>/dev/null
    APP_GROUP=$(/usr/libexec/PlistBuddy \
        -c 'Print :com.apple.security.application-groups:0' \
        "$APP_ENTITLEMENTS_CHECK" 2>/dev/null || true)
    EXTENSION_GROUP=$(/usr/libexec/PlistBuddy \
        -c 'Print :com.apple.security.application-groups:0' \
        "$EXTENSION_ENTITLEMENTS_CHECK" 2>/dev/null || true)
    if [[ "$APP_GROUP" != "T84BKD53ZD.com.linlu.hillstoneconnect" || \
          "$EXTENSION_GROUP" != "$APP_GROUP" ]]; then
        echo "ERROR: Signed app and System Extension do not share the required App Group." >&2
        exit 24
    fi
fi

echo "$OUTPUT_APP"
