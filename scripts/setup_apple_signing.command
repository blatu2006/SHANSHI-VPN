#!/bin/zsh
set -euo pipefail
setopt null_glob

CONFIG_ROOT="$HOME/.apple-signing"
CONFIG_DIR="$CONFIG_ROOT/nlvc-vpn"
CONFIG_PLIST="$CONFIG_DIR/config.plist"
SIGNING_GUIDE_SOURCE="${0:A:h:h}/Packaging/SigningRequirements.md"
SIGNING_GUIDE="$CONFIG_DIR/README.md"
PROJECT_DIR="${0:A:h:h}"
LOG_FILE="$PROJECT_DIR/.build/setup-apple-signing.log"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
NOTARY_PROFILE="NLVC-VPN-Notary"
TEAM_ID="T84BKD53ZD"
APPLICATION_IDENTITY="Developer ID Application: lu lin (T84BKD53ZD)"
INSTALLER_IDENTITY="Developer ID Installer: lu lin (T84BKD53ZD)"
APP_PROFILE=""
EXTENSION_PROFILE=""
APPLE_ID=""
CREDENTIALS_CONFIGURED=false

mkdir -p "$CONFIG_DIR" "$PROJECT_DIR/.build"
WORK_DIR=$(mktemp -d "$PROJECT_DIR/.build/signing-setup.XXXXXX")
trap '/bin/rm -rf "$WORK_DIR"' EXIT
chmod 700 "$CONFIG_ROOT" "$CONFIG_DIR"
cp "$SIGNING_GUIDE_SOURCE" "$SIGNING_GUIDE"
chmod 600 "$SIGNING_GUIDE"
exec > >(tee "$LOG_FILE") 2>&1

echo "NLVC VPN Apple signing setup"
echo
decode_profile() {
    local source="$1"
    local destination="$2"
    security cms -D -i "$source" >"$destination" 2>/dev/null || \
        /usr/bin/openssl smime -inform der -verify -noverify \
            -in "$source" -out "$destination" 2>/dev/null
}

array_contains() {
    local plist="$1"
    local key="$2"
    local expected="$3"
    local index=0
    local value
    while value=$(/usr/libexec/PlistBuddy -c "Print :$key:$index" "$plist" 2>/dev/null); do
        [[ "$value" == "$expected" ]] && return 0
        index=$((index + 1))
    done
    return 1
}

profile_is_usable() {
    local plist="$1"
    local identifier="$2"
    local require_installer="$3"
    local actual_identifier
    local system_extension
    actual_identifier=$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null || true)
    [[ "$actual_identifier" == "$TEAM_ID.$identifier" ]] || return 1
    array_contains "$plist" \
        'Entitlements:com.apple.developer.networking.networkextension' \
        'packet-tunnel-provider-systemextension' || return 1
    if [[ "$require_installer" == true ]]; then
        system_extension=$(/usr/libexec/PlistBuddy \
            -c 'Print :Entitlements:com.apple.developer.system-extension.install' \
            "$plist" 2>/dev/null || true)
        [[ "$system_extension" == true ]] || return 1
    fi
    return 0
}

for profile_path in "$PROFILE_DIR"/*.provisionprofile; do
    [[ -f "$profile_path" ]] || continue
    profile_plist="$WORK_DIR/${profile_path:t}.plist"
    decode_profile "$profile_path" "$profile_plist" || continue
    profile_name=$(plutil -extract Name raw "$profile_plist" 2>/dev/null || true)
    case "$profile_name" in
        'Mac Team Direct Provisioning Profile: com.linlu.hillstoneconnect')
            if profile_is_usable "$profile_plist" \
                com.linlu.hillstoneconnect true; then
                APP_PROFILE="$profile_path"
            fi
            ;;
        'Mac Team Direct Provisioning Profile: com.linlu.hillstoneconnect.PacketTunnel')
            if profile_is_usable "$profile_plist" \
                com.linlu.hillstoneconnect.PacketTunnel false; then
                EXTENSION_PROFILE="$profile_path"
            fi
            ;;
    esac
done

if [[ -z "$APP_PROFILE" || -z "$EXTENSION_PROFILE" ]]; then
    echo "ERROR: Usable Developer ID provisioning profiles are missing."
    echo "Both profiles must authorize packet-tunnel-provider-systemextension;"
    echo "the container profile must also authorize System Extension installation."
    exit 4
fi

security find-identity -v -p codesigning | grep -F "$APPLICATION_IDENTITY" >/dev/null || {
    echo "ERROR: $APPLICATION_IDENTITY is not available with its private key."
    exit 3
}

if [[ -f "$CONFIG_PLIST" ]]; then
    APPLE_ID=$(plutil -extract AppleID raw "$CONFIG_PLIST" 2>/dev/null || true)
    configured_team=$(plutil -extract TeamID raw "$CONFIG_PLIST" 2>/dev/null || true)
    configured_profile=$(plutil -extract NotaryKeychainProfile raw "$CONFIG_PLIST" 2>/dev/null || true)
    if [[ -n "$APPLE_ID" && "$configured_team" == "$TEAM_ID" && \
          -n "$configured_profile" ]]; then
        NOTARY_PROFILE="$configured_profile"
        CREDENTIALS_CONFIGURED=true
    fi
fi

if [[ "$CREDENTIALS_CONFIGURED" != true ]]; then
    read "APPLE_ID?Developer Apple ID for team $TEAM_ID: "
    if [[ -z "$APPLE_ID" ]]; then
        echo "ERROR: Apple ID cannot be empty."
        exit 2
    fi

    echo
    echo "Enter the app-specific password at the secure prompt."
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID"
else
    echo "Reusing existing notarization credential: $NOTARY_PROFILE"
fi

cp "$APP_PROFILE" "$CONFIG_DIR/NLVC-App.provisionprofile"
cp "$EXTENSION_PROFILE" "$CONFIG_DIR/NLVC-PacketTunnel.provisionprofile"
chmod 600 "$CONFIG_DIR/NLVC-App.provisionprofile" "$CONFIG_DIR/NLVC-PacketTunnel.provisionprofile"

plutil -create xml1 "$CONFIG_PLIST"
plutil -insert AppleID -string "$APPLE_ID" "$CONFIG_PLIST"
plutil -insert TeamID -string "$TEAM_ID" "$CONFIG_PLIST"
plutil -insert NotaryKeychainProfile -string "$NOTARY_PROFILE" "$CONFIG_PLIST"
plutil -insert ApplicationIdentity -string "$APPLICATION_IDENTITY" "$CONFIG_PLIST"
plutil -insert InstallerIdentity -string "$INSTALLER_IDENTITY" "$CONFIG_PLIST"
chmod 600 "$CONFIG_PLIST"
unset APPLE_ID

echo
"$PROJECT_DIR/scripts/check_apple_signing.command" --developer-id
echo
echo "APPLE_SIGNING_SETUP_RESULT=SUCCESS"
echo "Configuration: $CONFIG_PLIST"
echo "The app-specific password is stored only in the macOS Keychain."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Packaging/XcodeApp-Info.plist")
SIGNED_PKG="$PROJECT_DIR/dist/release-$VERSION/NLVC-VPN-$VERSION.pkg"
if [[ -f "$SIGNED_PKG" ]]; then
    echo
    echo "Continuing with notarization of the signed installer..."
    "$PROJECT_DIR/scripts/notarize_pkg.command"
fi
