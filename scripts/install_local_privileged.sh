#!/bin/zsh
set -euo pipefail

SOURCE_APP="$1"
TARGET_APP="$2"
BACKUP_APP="$3"

[[ "$TARGET_APP" == "/Applications/NLVC VPN.app" ]] || {
    echo "Refusing unexpected install target: $TARGET_APP" >&2
    exit 2
}
[[ -d "$SOURCE_APP" ]] || {
    echo "Source app is missing: $SOURCE_APP" >&2
    exit 3
}

if [[ -n "$BACKUP_APP" ]]; then
    /bin/mv "$TARGET_APP" "$BACKUP_APP"
fi
if ! /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"; then
    if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
        /bin/mv "$BACKUP_APP" "$TARGET_APP"
    fi
    exit 4
fi
