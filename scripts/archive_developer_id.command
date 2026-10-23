#!/bin/zsh
set -o pipefail

PROJECT_DIR="${0:A:h:h}"
PACKAGING_MODE=$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel' \
    "$PROJECT_DIR/Packaging/PacketTunnelSystemExtension-Info.plist" 2>/dev/null || true)
if [[ -z "$PACKAGING_MODE" ]]; then
    echo "ERROR: Developer ID archive requires the Packet Tunnel System Extension target."
    exit 20
fi
LOG_DIR="$PROJECT_DIR/.build"
LOG_FILE="$LOG_DIR/archive-developer-id.log"
ARCHIVE="$LOG_DIR/NLVC-VPN-DeveloperID.xcarchive"
DERIVED_DIR="$LOG_DIR/developer-id-derived"

mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_FILE") 2>&1

echo "NLVC VPN manual Developer ID archive"
echo "Started: $(date)"
echo
rm -rf "$ARCHIVE" "$DERIVED_DIR"
xcodebuild \
    -project "$PROJECT_DIR/HillstoneConnect.xcodeproj" \
    -scheme HillstoneConnect \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DIR" \
    -archivePath "$ARCHIVE" \
    archive \
    CODE_SIGN_STYLE=Automatic \
    'CODE_SIGN_IDENTITY=Developer ID Application' \
    NLVC_APP_ENTITLEMENTS=Packaging/HillstoneConnect-DeveloperID.entitlements \
    NLVC_EXTENSION_ENTITLEMENTS=Packaging/PacketTunnel-DeveloperID.entitlements
RESULT=$?

echo
if [[ $RESULT -eq 0 ]]; then
    echo "DEVELOPER_ID_ARCHIVE_RESULT=SUCCESS"
else
    echo "DEVELOPER_ID_ARCHIVE_RESULT=FAILED:$RESULT"
fi
echo "Finished: $(date)"
exit $RESULT
