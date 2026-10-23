#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VERSION=$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Packaging/XcodeApp-Info.plist")
RELEASE_DIR="$PROJECT_DIR/dist/release-$VERSION"
SOURCE_PKG="$RELEASE_DIR/NLVC-VPN-$VERSION.pkg"
OUTPUT_DMG="$RELEASE_DIR/NLVC-VPN-$VERSION.dmg"
PKG_STATUS="$RELEASE_DIR/RELEASE-STATUS.txt"
DMG_STATUS="$RELEASE_DIR/DMG-STATUS.txt"
LOG_FILE="$PROJECT_DIR/.build/build-notarized-dmg.log"
SIGNING_CONFIG_DIR="$HOME/.apple-signing/nlvc-vpn"
SIGNING_CONFIG="$SIGNING_CONFIG_DIR/config.plist"
APP_PROFILE="$SIGNING_CONFIG_DIR/NLVC-App.provisionprofile"

mkdir -p "$PROJECT_DIR/.build" "$RELEASE_DIR"
exec > >(tee "$LOG_FILE") 2>&1

/usr/bin/printf '%s\n' \
    'STATUS=NOT_READY' \
    'REASON=DMG build or notarization has not completed.' \
    > "$DMG_STATUS"

echo "NLVC VPN notarized DMG"
echo "Started: $(date)"
echo

if [[ ! -f "$SOURCE_PKG" || ! -f "$PKG_STATUS" ]]; then
    echo "ERROR: Release package or its status file is missing."
    exit 2
fi
if ! grep -qx 'STATUS=READY' "$PKG_STATUS"; then
    echo "ERROR: Refusing to wrap a package that is not release-ready."
    exit 3
fi

EXPECTED_PKG_SHA=$(sed -n 's/^SHA256=//p' "$PKG_STATUS" | head -1)
ACTUAL_PKG_SHA=$(shasum -a 256 "$SOURCE_PKG" | awk '{print $1}')
if [[ -z "$EXPECTED_PKG_SHA" || "$EXPECTED_PKG_SHA" != "$ACTUAL_PKG_SHA" ]]; then
    echo "ERROR: Release package SHA-256 does not match RELEASE-STATUS.txt."
    exit 4
fi
pkgutil --check-signature "$SOURCE_PKG"
xcrun stapler validate "$SOURCE_PKG"

if [[ ! -f "$SIGNING_CONFIG" || ! -f "$APP_PROFILE" ]]; then
    echo "ERROR: Machine-local signing configuration is incomplete."
    exit 5
fi
NOTARY_PROFILE=$(plutil -extract NotaryKeychainProfile raw "$SIGNING_CONFIG" 2>/dev/null)
if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "ERROR: NotaryKeychainProfile is missing from signing configuration."
    exit 6
fi

WORK_DIR=$(mktemp -d "$PROJECT_DIR/.build/dmg.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PROFILE_PLIST="$WORK_DIR/app-profile.plist"
PROFILE_CERT="$WORK_DIR/app-profile-certificate.der"
if ! security cms -D -i "$APP_PROFILE" > "$PROFILE_PLIST" 2>/dev/null; then
    /usr/bin/openssl smime -inform der -verify -noverify \
        -in "$APP_PROFILE" -out "$PROFILE_PLIST" 2>/dev/null
fi
plutil -extract DeveloperCertificates.0 raw -o - "$PROFILE_PLIST" | \
    /usr/bin/base64 -D > "$PROFILE_CERT"
APPLICATION_IDENTITY=$(openssl x509 -inform DER -in "$PROFILE_CERT" \
    -noout -fingerprint -sha1 | sed 's/^.*=//; s/://g')
if [[ -z "$APPLICATION_IDENTITY" ]]; then
    echo "ERROR: Cannot derive the Developer ID Application certificate from the profile."
    exit 7
fi
security find-identity -v -p codesigning | grep -F "$APPLICATION_IDENTITY" >/dev/null || {
    echo "ERROR: The Developer ID Application identity authorized by the profile is unavailable."
    exit 8
}

STAGING_DIR="$WORK_DIR/NLVC VPN $VERSION"
mkdir -p "$STAGING_DIR"
ditto "$SOURCE_PKG" "$STAGING_DIR/NLVC VPN $VERSION.pkg"

rm -f "$OUTPUT_DMG"
hdiutil create \
    -volname "NLVC VPN $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$OUTPUT_DMG"

codesign --force --timestamp --sign "$APPLICATION_IDENTITY" "$OUTPUT_DMG"
codesign --verify --strict --verbose=2 "$OUTPUT_DMG"

echo
echo "Submitting signed DMG to Apple..."
xcrun notarytool submit "$OUTPUT_DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$OUTPUT_DMG"
xcrun stapler validate "$OUTPUT_DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$OUTPUT_DMG"

DMG_SHA=$(shasum -a 256 "$OUTPUT_DMG" | awk '{print $1}')
/usr/bin/printf '%s\n' \
    'STATUS=READY' \
    "DMG=$OUTPUT_DMG" \
    "SHA256=$DMG_SHA" \
    > "$DMG_STATUS"

echo
echo "DMG_RESULT=SUCCESS"
echo "DMG=$OUTPUT_DMG"
echo "SHA256=$DMG_SHA"
echo "Finished: $(date)"
