#!/bin/zsh
set -o pipefail

PROJECT_DIR="${0:A:h:h}"
LOG_FILE="$PROJECT_DIR/.build/system-extension-diagnostics.log"
APP="/Applications/NLVC VPN.app"
EXTENSION="$APP/Contents/Library/SystemExtensions/com.linlu.hillstoneconnect.PacketTunnel.systemextension"

mkdir -p "$PROJECT_DIR/.build"
{
    echo "NLVC VPN installed system extension diagnostics"
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
    echo "=== Registered system extensions ==="
    /usr/bin/systemextensionsctl list 2>&1
    echo
    echo "=== Recent launch and Network Extension logs ==="
    /usr/bin/log show --last 45m --style compact \
        --predicate '(process == "neagent") OR (process == "nesessionmanager") OR (process == "sysextd") OR (process == "taskgated-helper") OR (process == "amfid") OR (subsystem == "com.apple.networkextension") OR (subsystem == "com.apple.system_extension") OR (eventMessage CONTAINS[c] "com.linlu.hillstoneconnect") OR (eventMessage CONTAINS[c] "NLVC VPN")' 2>&1
    echo
    echo "Finished: $(date)"
} >"$LOG_FILE"

/usr/bin/open -R "$LOG_FILE"
