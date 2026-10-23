#!/bin/zsh
set -o pipefail

PROJECT_DIR="${0:A:h:h}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Packaging/XcodeApp-Info.plist")
mkdir -p "$PROJECT_DIR/.build"
BUILD_DIR=$(mktemp -d "$PROJECT_DIR/.build/developer-id.XXXXXX") || exit $?
PRODUCT_APP="$BUILD_DIR/Build/Products/Release/NLVC VPN.app"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
SIGNING_CONFIG_DIR="$HOME/.apple-signing/nlvc-vpn"
SIGNING_CONFIG="$SIGNING_CONFIG_DIR/config.plist"
OUTPUT_DIR="$PROJECT_DIR/dist/release-$VERSION"
OUTPUT_APP="$OUTPUT_DIR/NLVC VPN.app"
OUTPUT_PKG="$OUTPUT_DIR/NLVC-VPN-$VERSION.pkg"
COMPONENT_PKG="$BUILD_DIR/NLVC-VPN-component.pkg"
PACKAGE_ROOT="$BUILD_DIR/package-root"
COMPONENT_PLIST="$BUILD_DIR/components.plist"
DISTRIBUTION_XML="$BUILD_DIR/Distribution.xml"
LOG_FILE="$PROJECT_DIR/.build/build-developer-id-pkg.log"
RELEASE_STATUS="$OUTPUT_DIR/RELEASE-STATUS.txt"
APPLICATION_IDENTITY="Developer ID Application: lu lin (T84BKD53ZD)"
INSTALLER_IDENTITY="Developer ID Installer: lu lin (T84BKD53ZD)"
APP_PROFILE="$SIGNING_CONFIG_DIR/NLVC-App.provisionprofile"
EXTENSION_PROFILE="$SIGNING_CONFIG_DIR/NLVC-PacketTunnel.provisionprofile"
APP_GROUP="T84BKD53ZD.com.linlu.hillstoneconnect"

if [[ -f "$SIGNING_CONFIG" ]]; then
    APPLICATION_IDENTITY=$(plutil -extract ApplicationIdentity raw "$SIGNING_CONFIG" 2>/dev/null || \
        echo "$APPLICATION_IDENTITY")
    INSTALLER_IDENTITY=$(plutil -extract InstallerIdentity raw "$SIGNING_CONFIG" 2>/dev/null || \
        echo "$INSTALLER_IDENTITY")
fi

mkdir -p "$OUTPUT_DIR"
exec > >(tee "$LOG_FILE") 2>&1

/usr/bin/printf '%s\n' \
    'STATUS=NOT_READY' \
    'REASON=Build has not completed; any existing PKG in this directory may be stale.' \
    > "$RELEASE_STATUS"

echo "NLVC VPN Developer ID package"
echo "Started: $(date)"
echo

"$PROJECT_DIR/scripts/check_apple_signing.command" --developer-id || exit $?
echo

PROVIDER_INFO="$PROJECT_DIR/Packaging/PacketTunnelSystemExtension-Info.plist"
PACKAGING_MODE=$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel' \
    "$PROVIDER_INFO" 2>/dev/null || true)
if [[ -z "$PACKAGING_MODE" ]]; then
    echo "ERROR: Refusing Developer ID packaging without a Packet Tunnel System Extension."
    exit 20
fi

if [[ ! -f "$APP_PROFILE" || ! -f "$EXTENSION_PROFILE" ]]; then
    APP_PROFILE=""
    EXTENSION_PROFILE=""
    for profile_path in "$PROFILE_DIR"/*.provisionprofile; do
        [[ -f "$profile_path" ]] || continue
        profile_name=$(security cms -D -i "$profile_path" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null)
        case "$profile_name" in
            'Mac Team Direct Provisioning Profile: com.linlu.hillstoneconnect')
                APP_PROFILE="$profile_path"
                ;;
            'Mac Team Direct Provisioning Profile: com.linlu.hillstoneconnect.PacketTunnel')
                EXTENSION_PROFILE="$profile_path"
                ;;
        esac
    done
fi

if [[ -z "$APP_PROFILE" || -z "$EXTENSION_PROFILE" ]]; then
    echo "ERROR: Developer ID provisioning profiles were not found."
    exit 2
fi

APP_PROFILE_PLIST="$BUILD_DIR/app-profile.plist"
EXTENSION_PROFILE_PLIST="$BUILD_DIR/extension-profile.plist"
decode_profile() {
    local source="$1"
    local destination="$2"
    security cms -D -i "$source" >"$destination" 2>/dev/null || \
        /usr/bin/openssl smime -inform der -verify -noverify \
            -in "$source" -out "$destination" 2>/dev/null
}
decode_profile "$APP_PROFILE" "$APP_PROFILE_PLIST" || {
    echo "ERROR: Cannot decode the app provisioning profile."
    exit 13
}
decode_profile "$EXTENSION_PROFILE" "$EXTENSION_PROFILE_PLIST" || {
    echo "ERROR: Cannot decode the packet tunnel provisioning profile."
    exit 14
}
profile_certificate_hashes() {
    local plist="$1"
    local prefix="$2"
    local index=0
    local encoded
    local certificate
    local hash
    while encoded=$(plutil -extract "DeveloperCertificates.$index" raw -o - "$plist" 2>/dev/null); do
        certificate="$BUILD_DIR/$prefix-$index.der"
        print -rn -- "$encoded" | /usr/bin/base64 -D >"$certificate" || return 1
        hash=$(/usr/bin/openssl x509 -inform DER -in "$certificate" \
            -noout -fingerprint -sha1 2>/dev/null | /usr/bin/sed 's/^.*=//; s/://g')
        [[ -n "$hash" ]] && print -r -- "$hash"
        index=$((index + 1))
    done
}
APP_PROFILE_CERT_SHA1=""
EXTENSION_PROFILE_CERT_HASHES=$(profile_certificate_hashes \
    "$EXTENSION_PROFILE_PLIST" extension-profile-certificate)
AVAILABLE_CODE_SIGNING_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
for candidate in ${(f)$(profile_certificate_hashes \
    "$APP_PROFILE_PLIST" app-profile-certificate)}; do
    if print -r -- "$EXTENSION_PROFILE_CERT_HASHES" | /usr/bin/grep -Fqx "$candidate" && \
       print -r -- "$AVAILABLE_CODE_SIGNING_IDENTITIES" | /usr/bin/grep -Fq "$candidate"; then
        APP_PROFILE_CERT_SHA1="$candidate"
        break
    fi
done
if [[ -z "$APP_PROFILE_CERT_SHA1" ]]; then
    echo "ERROR: App and extension profiles do not share an authorized signing"
    echo "certificate whose private key is available in the login Keychain."
    exit 24
fi
APP_PROFILE_NE=$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.networking.networkextension:0' \
    "$APP_PROFILE_PLIST" 2>/dev/null || true)
EXTENSION_PROFILE_NE=$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.networking.networkextension:0' \
    "$EXTENSION_PROFILE_PLIST" 2>/dev/null || true)
APP_PROFILE_SYSTEM_EXTENSION=$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.system-extension.install' \
    "$APP_PROFILE_PLIST" 2>/dev/null || true)
if [[ "$APP_PROFILE_NE" != "packet-tunnel-provider-systemextension" || \
      "$EXTENSION_PROFILE_NE" != "packet-tunnel-provider-systemextension" || \
      "$APP_PROFILE_SYSTEM_EXTENSION" != "true" ]]; then
    echo "ERROR: Developer ID profiles must authorize the Packet Tunnel System Extension."
    exit 15
fi
INSTALLER_SIGNING_IDENTITY=$(security find-identity -v -p basic | \
    awk -v identity="$INSTALLER_IDENTITY" 'index($0, identity) { print $2; exit }')
if [[ -z "$INSTALLER_SIGNING_IDENTITY" ]]; then
    echo "ERROR: Developer ID Installer identity is unavailable."
    echo "Use Xcode > Settings > Accounts > Manage Certificates to create or download it."
    exit 21
fi

rm -rf "$OUTPUT_APP" "$OUTPUT_PKG"
xcodebuild \
    -project "$PROJECT_DIR/HillstoneConnect.xcodeproj" \
    -scheme HillstoneConnect \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    NLVC_UPDATE_MANIFEST_URL="${NLVC_UPDATE_MANIFEST_URL:-}" \
    NLVC_APP_ENTITLEMENTS=Packaging/HillstoneConnect-DeveloperID.entitlements \
    NLVC_EXTENSION_ENTITLEMENTS=Packaging/PacketTunnel-DeveloperID.entitlements \
    build || exit $?

PACKET_TUNNEL="$PRODUCT_APP/Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension"
if [[ ! -d "$PACKET_TUNNEL" ]]; then
    echo "ERROR: Embedded packet tunnel system extension is missing."
    exit 4
fi
if [[ -d "$PRODUCT_APP/Contents/PlugIns" ]]; then
    echo "ERROR: Build contains stale App Extension content."
    exit 16
fi

cp "$APP_PROFILE" "$PRODUCT_APP/Contents/embedded.provisionprofile"
cp "$EXTENSION_PROFILE" "$PACKET_TUNNEL/Contents/embedded.provisionprofile"
chmod 644 \
    "$PRODUCT_APP/Contents/embedded.provisionprofile" \
    "$PACKET_TUNNEL/Contents/embedded.provisionprofile"

codesign --force --timestamp --options runtime \
    --entitlements "$PROJECT_DIR/Packaging/PacketTunnel-DeveloperID.entitlements" \
    --sign "$APP_PROFILE_CERT_SHA1" "$PACKET_TUNNEL" || exit $?
codesign --force --timestamp --options runtime \
    --entitlements "$PROJECT_DIR/Packaging/HillstoneConnect-DeveloperID.entitlements" \
    --sign "$APP_PROFILE_CERT_SHA1" "$PRODUCT_APP" || exit $?

codesign --verify --deep --strict --verbose=2 "$PRODUCT_APP" || exit $?
codesign -dv --verbose=4 "$PRODUCT_APP" 2>&1 | grep -F 'Authority=Developer ID Application' || exit $?
codesign -dv --verbose=4 "$PACKET_TUNNEL" 2>&1 | grep -F 'Authority=Developer ID Application' || exit $?

ditto "$PRODUCT_APP" "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP" || exit $?
APP_ENTITLEMENTS_CHECK="$BUILD_DIR/app-signed-entitlements.plist"
EXTENSION_ENTITLEMENTS_CHECK="$BUILD_DIR/extension-signed-entitlements.plist"
OUTPUT_EXTENSION="$OUTPUT_APP/Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension"
codesign -d --entitlements "$APP_ENTITLEMENTS_CHECK" --xml "$OUTPUT_APP" 2>/dev/null || exit $?
codesign -d --entitlements "$EXTENSION_ENTITLEMENTS_CHECK" --xml "$OUTPUT_EXTENSION" 2>/dev/null || exit $?
APP_SIGNED_NE=$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.networking.networkextension:0' \
    "$APP_ENTITLEMENTS_CHECK" 2>/dev/null || true)
EXTENSION_SIGNED_NE=$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.networking.networkextension:0' \
    "$EXTENSION_ENTITLEMENTS_CHECK" 2>/dev/null || true)
APP_SIGNED_SYSTEM_EXTENSION=$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.system-extension.install' \
    "$APP_ENTITLEMENTS_CHECK" 2>/dev/null || true)
EXTENSION_CLASS=$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel' \
    "$OUTPUT_EXTENSION/Contents/Info.plist" 2>/dev/null || true)
MACH_SERVICE=$(/usr/libexec/PlistBuddy \
    -c 'Print :NetworkExtension:NEMachServiceName' \
    "$OUTPUT_EXTENSION/Contents/Info.plist" 2>/dev/null || true)
APP_SIGNED_GROUP=$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.application-groups:0' \
    "$APP_ENTITLEMENTS_CHECK" 2>/dev/null || true)
EXTENSION_SIGNED_GROUP=$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.application-groups:0' \
    "$EXTENSION_ENTITLEMENTS_CHECK" 2>/dev/null || true)
if [[ "$APP_SIGNED_NE" != "packet-tunnel-provider-systemextension" || \
      "$EXTENSION_SIGNED_NE" != "packet-tunnel-provider-systemextension" || \
      "$APP_SIGNED_SYSTEM_EXTENSION" != "true" ]]; then
    echo "ERROR: Signed app and extension lack Developer ID System Extension entitlements."
    exit 5
fi
if [[ -z "$EXTENSION_CLASS" ]]; then
    echo "ERROR: Packet tunnel System Extension lacks its provider class."
    exit 11
fi
if [[ "$APP_SIGNED_GROUP" != "$APP_GROUP" || \
      "$EXTENSION_SIGNED_GROUP" != "$APP_GROUP" ]]; then
    echo "ERROR: App and System Extension must share App Group $APP_GROUP."
    exit 12
fi
if [[ "$MACH_SERVICE" != "$APP_GROUP."* ]]; then
    echo "ERROR: NEMachServiceName must be a child of signed App Group $APP_GROUP."
    exit 18
fi
for forbidden in keychain-access-groups; do
    if /usr/libexec/PlistBuddy -c "Print :$forbidden" "$APP_ENTITLEMENTS_CHECK" >/dev/null 2>&1 || \
       /usr/libexec/PlistBuddy -c "Print :$forbidden" "$EXTENSION_ENTITLEMENTS_CHECK" >/dev/null 2>&1; then
        echo "ERROR: Obsolete entitlement remains in signed product: $forbidden"
        exit 12
    fi
done
if [[ "$OUTPUT_EXTENSION" != "$OUTPUT_APP/Contents/Library/SystemExtensions/"*.systemextension ]]; then
    echo "ERROR: System Extension was embedded in the wrong location."
    exit 17
fi

mkdir -p "$PACKAGE_ROOT/Applications"
ditto "$OUTPUT_APP" "$PACKAGE_ROOT/Applications/NLVC VPN.app"

# pkgbuild otherwise marks application bundles as relocatable. On a developer
# Mac, LaunchServices may then redirect the payload to a previously registered
# DerivedData/.build copy instead of /Applications. Generate an explicit
# component policy and pin the app to the package root destination.
pkgbuild --analyze --root "$PACKAGE_ROOT" "$COMPONENT_PLIST" || exit $?
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$COMPONENT_PLIST" || exit $?
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked false' "$COMPONENT_PLIST" || exit $?
pkgbuild \
    --root "$PACKAGE_ROOT" \
    --component-plist "$COMPONENT_PLIST" \
    --install-location / \
    --identifier com.linlu.hillstoneconnect \
    --version "$VERSION" \
    --scripts "$PROJECT_DIR/Packaging/InstallerScripts" \
    "$COMPONENT_PKG" || exit $?
productbuild --synthesize --package "$COMPONENT_PKG" "$DISTRIBUTION_XML" || exit $?
/usr/bin/perl -0pi -e \
    's|(<installer-gui-script[^>]*>)|$1\n    <title>NLVC VPN</title>|' \
    "$DISTRIBUTION_XML" || exit $?
productbuild \
    --distribution "$DISTRIBUTION_XML" \
    --package-path "$BUILD_DIR" \
    --sign "$INSTALLER_SIGNING_IDENTITY" \
    "$OUTPUT_PKG" || exit $?
pkgutil --check-signature "$OUTPUT_PKG" || exit $?

PACKAGE_CHECK="$BUILD_DIR/package-check"
pkgutil --expand-full "$OUTPUT_PKG" "$PACKAGE_CHECK" || exit $?
PAYLOAD_APP=$(find "$PACKAGE_CHECK" -type d -path '*/Payload/Applications/NLVC VPN.app' -print -quit)
POSTINSTALL_SCRIPT=$(find "$PACKAGE_CHECK" -type f -path '*/Scripts/postinstall' -print -quit)
PREINSTALL_SCRIPT=$(find "$PACKAGE_CHECK" -type f -path '*/Scripts/preinstall' -print -quit)
PACKAGE_INFO=$(find "$PACKAGE_CHECK" -type f -name PackageInfo -print -quit)
if [[ -z "$PAYLOAD_APP" ]]; then
    echo "ERROR: Package payload does not install /Applications/NLVC VPN.app."
    exit 6
fi
PAYLOAD_EXTENSION="$PAYLOAD_APP/Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension"
if [[ ! -d "$PAYLOAD_EXTENSION" ]]; then
    echo "ERROR: Package payload is missing the Packet Tunnel System Extension."
    exit 26
fi
codesign --verify --deep --strict --verbose=2 "$PAYLOAD_APP" || {
    echo "ERROR: The app signature changed or became invalid inside the final PKG payload."
    exit 27
}
codesign --verify --strict --verbose=2 "$PAYLOAD_EXTENSION" || {
    echo "ERROR: The System Extension signature is invalid inside the final PKG payload."
    exit 28
}
if [[ -z "$POSTINSTALL_SCRIPT" || ! -x "$POSTINSTALL_SCRIPT" ]]; then
    echo "ERROR: Package is missing the executable postinstall launch script."
    exit 7
fi
if [[ -z "$PREINSTALL_SCRIPT" || ! -x "$PREINSTALL_SCRIPT" ]]; then
    echo "ERROR: Package is missing the executable preinstall old-process cleanup script."
    exit 19
fi
if [[ -z "$PACKAGE_INFO" ]]; then
    echo "ERROR: PackageInfo was not found in the expanded package."
    exit 8
fi
RELOCATION_RULES=$(/usr/bin/sed -n '/<relocate>/,/<\/relocate>/p' "$PACKAGE_INFO")
if print -r -- "$RELOCATION_RULES" | /usr/bin/grep -q '<bundle '; then
    echo "ERROR: Package still contains bundle relocation rules; it could miss /Applications."
    exit 9
fi
if ! /usr/bin/grep -q 'relocatable="false"' "$PACKAGE_INFO"; then
    echo "ERROR: Package does not explicitly disable bundle relocation."
    exit 10
fi

/usr/bin/printf '%s\n' \
    'STATUS=SIGNED_AWAITING_NOTARIZATION' \
    "PKG=$OUTPUT_PKG" \
    > "$RELEASE_STATUS"

echo
echo "DEVELOPER_ID_PACKAGE_RESULT=SUCCESS"
echo "APP=$OUTPUT_APP"
echo "PKG=$OUTPUT_PKG"
echo "Finished: $(date)"
