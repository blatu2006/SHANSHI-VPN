#!/bin/zsh
set -o pipefail

PROJECT_DIR="${0:A:h:h}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Packaging/XcodeApp-Info.plist")
PKG="$PROJECT_DIR/dist/release-$VERSION/NLVC-VPN-$VERSION.pkg"
LOG_FILE="$PROJECT_DIR/.build/notarize-pkg.log"
RELEASE_STATUS="$PROJECT_DIR/dist/release-$VERSION/RELEASE-STATUS.txt"
PROFILE_NAME="NLVC-VPN-Notary"
TEAM_ID="T84BKD53ZD"
CONFIG_PLIST="$HOME/.apple-signing/nlvc-vpn/config.plist"

mkdir -p "$PROJECT_DIR/.build"
exec > >(tee "$LOG_FILE") 2>&1

APPLE_ID=""
CREDENTIALS_CONFIGURED=false
if [[ -f "$CONFIG_PLIST" ]]; then
    APPLE_ID=$(plutil -extract AppleID raw "$CONFIG_PLIST" 2>/dev/null || true)
    PROFILE_NAME=$(plutil -extract NotaryKeychainProfile raw "$CONFIG_PLIST" 2>/dev/null || echo "$PROFILE_NAME")
    TEAM_ID=$(plutil -extract TeamID raw "$CONFIG_PLIST" 2>/dev/null || echo "$TEAM_ID")
    if [[ -n "$APPLE_ID" && -n "$PROFILE_NAME" && -n "$TEAM_ID" ]]; then
        # setup_apple_signing.command writes this file only after notarytool
        # validates and saves the credential in Keychain. Avoid using a
        # network history request as a local credential-presence check.
        CREDENTIALS_CONFIGURED=true
    fi
fi

echo "NLVC VPN Apple notarization"
echo "Started: $(date)"
echo

if [[ ! -f "$PKG" ]]; then
    echo "ERROR: Signed installer not found: $PKG"
    exit 2
fi

if [[ "$CREDENTIALS_CONFIGURED" != true ]]; then
    echo "A notarization credential must be stored once."
    if [[ -z "$APPLE_ID" ]]; then
        read "APPLE_ID?Developer Apple ID: "
    fi
    echo "Enter the Apple app-specific password at the secure prompt."
    xcrun notarytool store-credentials "$PROFILE_NAME" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" || exit $?
    unset APPLE_ID
fi

echo
echo "Submitting signed installer to Apple..."
submit_attempt=1
submit_max_attempts=3
SUBMIT_LOG=$(mktemp "$PROJECT_DIR/.build/notary-submit.XXXXXX") || exit $?
while true; do
    if xcrun notarytool submit "$PKG" \
        --keychain-profile "$PROFILE_NAME" \
        --wait 2>&1 | tee "$SUBMIT_LOG"; then
        break
    fi
    submit_status=$?
    if grep -q 'No Keychain password item found' "$SUBMIT_LOG"; then
        echo "ERROR: Notary credential $PROFILE_NAME is missing."
        echo "Run scripts/refresh_notary_credentials.command, then retry notarization."
        exit 21
    fi
    if (( submit_attempt >= submit_max_attempts )); then
        echo "ERROR: Notarization failed after $submit_max_attempts attempts."
        exit "$submit_status"
    fi
    submit_attempt=$((submit_attempt + 1))
    echo "Apple notarization service was unreachable; retrying ($submit_attempt/$submit_max_attempts)..."
    sleep 5
done

xcrun stapler staple "$PKG" || exit $?
xcrun stapler validate "$PKG" || exit $?
spctl --assess --type install --verbose=2 "$PKG" || exit $?

SHA256=$(shasum -a 256 "$PKG" | awk '{print $1}')
/usr/bin/printf '%s\n' \
    'STATUS=READY' \
    "PKG=$PKG" \
    "SHA256=$SHA256" \
    > "$RELEASE_STATUS"
echo
echo "NOTARIZATION_RESULT=SUCCESS"
echo "PKG=$PKG"
echo "SHA256=$SHA256"
echo "Finished: $(date)"
