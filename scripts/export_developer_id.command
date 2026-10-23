#!/bin/zsh
set -o pipefail

PROJECT_DIR="${0:A:h:h}"
PACKAGING_MODE=$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel' \
    "$PROJECT_DIR/Packaging/PacketTunnelSystemExtension-Info.plist" 2>/dev/null || true)
if [[ -z "$PACKAGING_MODE" ]]; then
    echo "ERROR: Developer ID export requires the Packet Tunnel System Extension target."
    exit 20
fi
LOG_DIR="$PROJECT_DIR/.build"
LOG_FILE="$LOG_DIR/export-developer-id.log"
ARCHIVE="$LOG_DIR/NLVC-VPN.xcarchive"
EXPORT_DIR="$LOG_DIR/developer-id-export"

mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_FILE") 2>&1

echo "NLVC VPN Developer ID export"
echo "Started: $(date)"
echo
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$PROJECT_DIR/Packaging/ExportOptions-DeveloperID.plist" \
    -allowProvisioningUpdates
RESULT=$?

echo
if [[ $RESULT -eq 0 ]]; then
    echo "EXPORT_RESULT=SUCCESS"
else
    echo "EXPORT_RESULT=FAILED:$RESULT"
fi
echo "Finished: $(date)"
exit $RESULT
