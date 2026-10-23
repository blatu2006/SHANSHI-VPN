#!/bin/zsh
set -o pipefail

PROJECT_DIR="${0:A:h:h}"
PACKAGING_MODE=$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel' \
    "$PROJECT_DIR/Packaging/PacketTunnelSystemExtension-Info.plist" 2>/dev/null || true)
if [[ -z "$PACKAGING_MODE" ]]; then
    echo "ERROR: Notarization requires the Packet Tunnel System Extension target."
    exit 20
fi
LOG_DIR="$PROJECT_DIR/.build"
LOG_FILE="$LOG_DIR/archive-for-notarization.log"
ARCHIVE="$LOG_DIR/NLVC-VPN.xcarchive"
DERIVED_DIR="$LOG_DIR/notary-derived-terminal"

mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_FILE") 2>&1

echo "NLVC VPN Developer ID archive"
echo "Started: $(date)"
echo
security find-identity -v -p codesigning
echo

rm -rf "$ARCHIVE" "$DERIVED_DIR"
xcodebuild \
    -project "$PROJECT_DIR/HillstoneConnect.xcodeproj" \
    -scheme HillstoneConnect \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DIR" \
    -archivePath "$ARCHIVE" \
    archive -allowProvisioningUpdates
RESULT=$?

echo
if [[ $RESULT -eq 0 ]]; then
    echo "ARCHIVE_RESULT=SUCCESS"
else
    echo "ARCHIVE_RESULT=FAILED:$RESULT"
fi
echo "Finished: $(date)"
exit $RESULT
