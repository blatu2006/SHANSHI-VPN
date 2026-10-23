#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VERSION=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Packaging/XcodeApp-Info.plist")
PKG="$PROJECT_DIR/dist/release-$VERSION/NLVC-VPN-$VERSION.pkg"
LOG_FILE="$PROJECT_DIR/.build/install-release.log"

if [[ ! -f "$PKG" ]]; then
    echo "ERROR: Release package not found: $PKG"
    exit 2
fi

echo "Installing notarized NLVC VPN $VERSION from $PKG" | tee "$LOG_FILE"
sudo /usr/sbin/installer -pkg "$PKG" -target / 2>&1 | tee -a "$LOG_FILE"
result=${pipestatus[1]}
if [[ $result -ne 0 ]]; then
    echo "INSTALL_RELEASE_RESULT=FAILED:$result" | tee -a "$LOG_FILE"
    exit $result
fi

echo "INSTALL_RELEASE_RESULT=SUCCESS" | tee -a "$LOG_FILE"
