#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/.build"
exec > >(tee "$PROJECT_DIR/.build/install-local.log") 2>&1
SOURCE_APP="${1:-$PROJECT_DIR/dist/NLVC VPN.app}"
TARGET_APP="/Applications/NLVC VPN.app"
BACKUP_DIR="$PROJECT_DIR/archive/app-bundles"
EXPECTED_ID="com.linlu.hillstoneconnect"

verify_app() {
    local app="$1"
    local result
    if result=$(/usr/bin/codesign --verify --deep --strict "$app" 2>&1); then
        return 0
    fi
    # Apple Development certificates can be locally usable while their trust
    # chain is unavailable to the command-line verifier. Still require the
    # exact bundle and Team identifiers before allowing a local install.
    local details
    details=$(/usr/bin/codesign -dv --verbose=2 "$app" 2>&1)
    if [[ "$result" == *"CSSMERR_TP_NOT_TRUSTED"* \
        && "$details" == *"Identifier=$EXPECTED_ID"* \
        && "$details" == *"TeamIdentifier=T84BKD53ZD"* ]]; then
        echo "Warning: local development certificate trust chain is unavailable; identifiers verified."
        return 0
    fi
    echo "$result" >&2
    return 1
}

[[ -d "$SOURCE_APP" ]] || { echo "App not found: $SOURCE_APP" >&2; exit 1; }
ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")
[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || { echo "Unexpected bundle id: $ACTUAL_ID" >&2; exit 1; }
verify_app "$SOURCE_APP"

mkdir -p "$BACKUP_DIR"
/usr/bin/osascript -e 'tell application id "com.linlu.hillstoneconnect" to quit' 2>/dev/null || true
if [[ -d "$TARGET_APP" ]]; then
    STAMP=$(date +%Y%m%d-%H%M%S)
    BACKUP_APP="$BACKUP_DIR/installed-$STAMP.bundle-backup"
    # Move the complete old bundle out of /Applications before installing.
    # Copying over an existing signed bundle can leave stale resources behind
    # and can confuse LaunchServices about the bundle executable.
else
    BACKUP_APP=""
fi

if [[ ! -w "/Applications" ]]; then
    /usr/bin/osascript \
        -e 'on run argv' \
        -e 'set helper to item 1 of argv' \
        -e 'set sourceApp to item 2 of argv' \
        -e 'set targetApp to item 3 of argv' \
        -e 'set backupApp to item 4 of argv' \
        -e 'set installCommand to quoted form of helper & " " & quoted form of sourceApp & " " & quoted form of targetApp & " " & quoted form of backupApp' \
        -e 'do shell script installCommand with administrator privileges' \
        -e 'end run' \
        -- "$PROJECT_DIR/scripts/install_local_privileged.sh" "$SOURCE_APP" "$TARGET_APP" "$BACKUP_APP"
else
    if [[ -n "$BACKUP_APP" ]]; then
        /bin/mv "$TARGET_APP" "$BACKUP_APP"
    fi
    /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
fi
verify_app "$TARGET_APP"
echo "Installed: $TARGET_APP"
echo "Backups: $BACKUP_DIR"
