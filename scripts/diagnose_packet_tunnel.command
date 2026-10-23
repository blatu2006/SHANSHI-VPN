#!/bin/zsh
set -o pipefail

PROJECT_DIR="${0:A:h:h}"
LOG_FILE="$PROJECT_DIR/.build/system-extension-diagnostics.log"
APP="/Applications/NLVC VPN.app"
EXTENSION="$APP/Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension"

mkdir -p "$PROJECT_DIR/.build"
{
    echo "NLVC VPN packet tunnel system extension diagnostics"
    echo "Started: $(date)"
    echo
    echo "=== Paths ==="
    /bin/ls -ldeO@ "$APP" "$EXTENSION" 2>&1
    echo
    echo "=== App signature ==="
    /usr/bin/codesign --verify --deep --strict --verbose=4 "$APP" 2>&1
    /usr/bin/codesign -dvvv "$APP" 2>&1
    /usr/bin/codesign -d --entitlements - --xml "$APP" 2>&1
    echo
    echo "=== Extension signature ==="
    /usr/bin/codesign --verify --strict --verbose=4 "$EXTENSION" 2>&1
    /usr/bin/codesign -dvvv "$EXTENSION" 2>&1
    /usr/bin/codesign -d --entitlements - --xml "$EXTENSION" 2>&1
    echo
    echo "=== Provisioning profiles ==="
    /usr/bin/security cms -D -i "$APP/Contents/embedded.provisionprofile" 2>/dev/null \
        | /usr/bin/plutil -extract Entitlements xml1 -o - - 2>&1
    /usr/bin/security cms -D -i "$EXTENSION/Contents/embedded.provisionprofile" 2>/dev/null \
        | /usr/bin/plutil -extract Entitlements xml1 -o - - 2>&1
    echo
    echo "=== Registered system extensions ==="
    /usr/bin/systemextensionsctl list 2>&1
    echo
    echo "=== Recent Network Extension logs ==="
    /usr/bin/log show --last 30m --style compact \
        --predicate '(process == "neagent") OR (process == "nesessionmanager") OR (subsystem == "com.apple.networkextension") OR (eventMessage CONTAINS[c] "com.linlu.hillstoneconnect")' 2>&1
    echo
    echo "Finished: $(date)"
} >"$LOG_FILE"

/usr/bin/open -R "$LOG_FILE"
