#!/bin/zsh
set -euo pipefail

CONFIG_PLIST="$HOME/.apple-signing/nlvc-vpn/config.plist"
PROFILE_NAME="NLVC-VPN-Notary"
TEAM_ID="T84BKD53ZD"

if [[ ! -f "$CONFIG_PLIST" ]]; then
    echo "ERROR: Missing signing configuration: $CONFIG_PLIST"
    exit 2
fi

APPLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :AppleID' "$CONFIG_PLIST")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :NotaryKeychainProfile' "$CONFIG_PLIST")
TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :TeamID' "$CONFIG_PLIST")

echo "Apple will securely prompt for the app-specific password for $APPLE_ID."
xcrun notarytool store-credentials "$PROFILE_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID"
unset APPLE_ID

echo
echo "NOTARY_CREDENTIAL_REFRESH_RESULT=SUCCESS"
