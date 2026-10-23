#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP="$PROJECT_DIR/dist/NLVC VPN.app"
VERSION=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Packaging/XcodeApp-Info.plist")
PKG="$PROJECT_DIR/dist/NLVC-VPN-$VERSION-local.pkg"
BUILD_DIR=$(mktemp -d "$PROJECT_DIR/.build/local-installer.XXXXXX")
PACKAGE_ROOT="$BUILD_DIR/root"
COMPONENT_PLIST="$BUILD_DIR/components.plist"

if [[ "${1:-}" != "--no-build" ]]; then
    "$PROJECT_DIR/scripts/build_app.sh"
fi

[[ -d "$APP/Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension" ]] || {
    echo "ERROR: Signed app is missing the Packet Tunnel System Extension." >&2
    exit 20
}
[[ ! -d "$APP/Contents/PlugIns" ]] || {
    echo "ERROR: Refusing to package stale App Extension content." >&2
    exit 21
}

/bin/mkdir -p "$PACKAGE_ROOT/Applications"
/usr/bin/ditto "$APP" "$PACKAGE_ROOT/Applications/NLVC VPN.app"
/usr/bin/pkgbuild --analyze --root "$PACKAGE_ROOT" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked false' "$COMPONENT_PLIST"

/usr/bin/pkgbuild \
    --root "$PACKAGE_ROOT" \
    --component-plist "$COMPONENT_PLIST" \
    --install-location / \
    --identifier com.linlu.hillstoneconnect.local \
    --version "$VERSION" \
    --scripts "$PROJECT_DIR/Packaging/InstallerScripts" \
    "$PKG"

echo "$PKG"
