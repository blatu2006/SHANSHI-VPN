#!/bin/zsh
set -euo pipefail
setopt null_glob

PROJECT_DIR="${0:A:h:h}"
MODE="${1:---all}"
TEAM_ID="T84BKD53ZD"
APP_ID="com.linlu.hillstoneconnect"
EXTENSION_ID="com.linlu.hillstoneconnect.PacketTunnel"
APP_GROUP="$TEAM_ID.$APP_ID"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
SIGNING_DIR="$HOME/.apple-signing/nlvc-vpn"
mkdir -p "$PROJECT_DIR/.build"
WORK_DIR=$(mktemp -d "$PROJECT_DIR/.build/signing-check.XXXXXX")
trap '/bin/rm -rf "$WORK_DIR"' EXIT

case "$MODE" in
    --all|--development|--developer-id) ;;
    *)
        echo "Usage: ${0:t} [--all|--development|--developer-id]" >&2
        exit 64
        ;;
esac

failures=0
profile_index=0
VALIDATED_PROFILE_PLIST=""

fail() {
    echo "ERROR: $*" >&2
    failures=$((failures + 1))
}

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

profile_certificate_hashes() {
    local plist="$1"
    local prefix="$2"
    local index=0
    local encoded
    local certificate
    local hash
    while encoded=$(plutil -extract "DeveloperCertificates.$index" raw -o - "$plist" 2>/dev/null); do
        certificate="$WORK_DIR/$prefix-$index.der"
        print -rn -- "$encoded" | /usr/bin/base64 -D >"$certificate" || return 1
        hash=$(/usr/bin/openssl x509 -inform DER -in "$certificate" \
            -noout -fingerprint -sha1 2>/dev/null | /usr/bin/sed 's/^.*=//; s/://g')
        [[ -n "$hash" ]] && print -r -- "$hash"
        index=$((index + 1))
    done
}

validate_profile() {
    local label="$1"
    local path="$2"
    local expected_identifier="$3"
    local require_installer="$4"
    local plist="$WORK_DIR/profile-$profile_index.plist"
    local identifier
    local team
    local expiration
    VALIDATED_PROFILE_PLIST=""
    profile_index=$((profile_index + 1))

    if [[ ! -f "$path" ]]; then
        fail "$label profile not found: $path"
        return 1
    fi
    if ! decode_profile "$path" "$plist"; then
        fail "$label profile cannot be decoded: $path"
        return 1
    fi
    VALIDATED_PROFILE_PLIST="$plist"

    identifier=$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null || true)
    team=$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.developer.team-identifier' "$plist" 2>/dev/null || true)
    expiration=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$plist" 2>/dev/null || echo unknown)

    [[ "$identifier" == "$TEAM_ID.$expected_identifier" ]] || \
        fail "$label profile authorizes '$identifier', expected '$TEAM_ID.$expected_identifier'."
    [[ "$team" == "$TEAM_ID" ]] || \
        fail "$label profile belongs to Team '$team', expected '$TEAM_ID'."
    array_contains "$plist" \
        'Entitlements:com.apple.developer.networking.networkextension' \
        'packet-tunnel-provider-systemextension' || \
        fail "$label profile lacks packet-tunnel-provider-systemextension."
    if [[ "$require_installer" == true ]]; then
        local system_extension
        system_extension=$(/usr/libexec/PlistBuddy \
            -c 'Print :Entitlements:com.apple.developer.system-extension.install' \
            "$plist" 2>/dev/null || true)
        [[ "$system_extension" == true ]] || \
            fail "$label profile lacks com.apple.developer.system-extension.install."
    fi

    echo "FOUND: $label profile (expires $expiration)"
}

profile_has_required_capabilities() {
    local plist="$1"
    local expected_identifier="$2"
    local require_installer="$3"
    local identifier
    local system_extension
    identifier=$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null || true)
    [[ "$identifier" == "$TEAM_ID.$expected_identifier" ]] || return 1
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

find_profile_by_name() {
    local expected_name="$1"
    local expected_identifier="$2"
    local require_installer="$3"
    local profile
    local plist
    local name
    local fallback=""
    for profile in "$PROFILE_DIR"/*.provisionprofile; do
        plist="$WORK_DIR/search-${profile:t}.plist"
        decode_profile "$profile" "$plist" || continue
        name=$(plutil -extract Name raw "$plist" 2>/dev/null || true)
        if [[ "$name" == "$expected_name" ]]; then
            fallback="$profile"
            if profile_has_required_capabilities \
                "$plist" "$expected_identifier" "$require_installer"; then
                print -r -- "$profile"
                return 0
            fi
        fi
    done
    if [[ -n "$fallback" ]]; then
        print -r -- "$fallback"
        return 0
    fi
    return 1
}

validate_common_identity() {
    local label="$1"
    local app_plist="$2"
    local extension_plist="$3"
    local identities
    local app_hash
    local extension_hashes

    identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
    extension_hashes=$(profile_certificate_hashes "$extension_plist" "${label// /-}-extension")
    for app_hash in ${(f)$(profile_certificate_hashes "$app_plist" "${label// /-}-app")}; do
        if print -r -- "$extension_hashes" | /usr/bin/grep -Fqx "$app_hash" && \
           print -r -- "$identities" | /usr/bin/grep -Fq "$app_hash"; then
            echo "OK: $label profiles share an installed signing identity ($app_hash)."
            return 0
        fi
    done
    fail "$label profiles do not share an authorized signing certificate with a local private key."
    return 1
}

check_developer_id() {
    local config="$SIGNING_DIR/config.plist"
    local app_profile="$SIGNING_DIR/NLVC-App.provisionprofile"
    local extension_profile="$SIGNING_DIR/NLVC-PacketTunnel.provisionprofile"
    local app_plist
    local extension_plist

    echo "Checking Developer ID signing..."
    [[ -f "$config" ]] || fail "Signing config not found: $config"
    validate_profile "Developer ID app" "$app_profile" "$APP_ID" true || true
    app_plist="$VALIDATED_PROFILE_PLIST"
    validate_profile "Developer ID extension" "$extension_profile" "$EXTENSION_ID" false || true
    extension_plist="$VALIDATED_PROFILE_PLIST"
    if [[ -f "$app_plist" && -f "$extension_plist" ]]; then
        validate_common_identity "Developer ID" "$app_plist" "$extension_plist" || true
    fi

    local installer_identity="Developer ID Installer: lu lin ($TEAM_ID)"
    if [[ -f "$config" ]]; then
        installer_identity=$(plutil -extract InstallerIdentity raw "$config" 2>/dev/null || echo "$installer_identity")
    fi
    security find-identity -v -p basic 2>/dev/null | /usr/bin/grep -F "$installer_identity" >/dev/null || \
        fail "Developer ID Installer identity is unavailable: $installer_identity"
}

check_development() {
    local app_profile
    local extension_profile
    local app_plist
    local extension_plist

    echo "Checking Apple Development signing..."
    app_profile=$(find_profile_by_name \
        "Mac Team Provisioning Profile: $APP_ID" "$APP_ID" true || true)
    extension_profile=$(find_profile_by_name \
        "Mac Team Provisioning Profile: $EXTENSION_ID" "$EXTENSION_ID" false || true)
    validate_profile "Development app" "$app_profile" "$APP_ID" true || true
    app_plist="$VALIDATED_PROFILE_PLIST"
    validate_profile "Development extension" "$extension_profile" "$EXTENSION_ID" false || true
    extension_plist="$VALIDATED_PROFILE_PLIST"
    if [[ -f "$app_plist" && -f "$extension_plist" ]]; then
        validate_common_identity "Development" "$app_plist" "$extension_plist" || true
    fi
}

case "$MODE" in
    --all)
        check_development
        check_developer_id
        ;;
    --development) check_development ;;
    --developer-id) check_developer_id ;;
esac

echo
if (( failures > 0 )); then
    echo "SIGNING_CHECK_RESULT=FAILED:$failures"
    echo "Enable the exact System Extension Packet Tunnel and App Group capabilities"
    echo "for both Apple Developer identifiers, regenerate the matching profiles,"
    echo "then rerun this command. The macOS Team-ID App Group is checked after signing."
    exit 1
fi

echo "SIGNING_CHECK_RESULT=SUCCESS"
