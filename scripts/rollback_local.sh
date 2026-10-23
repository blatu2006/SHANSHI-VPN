#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BACKUP_APP="${1:-}"

if [[ -z "$BACKUP_APP" ]]; then
    BACKUP_APP=$(find "$PROJECT_DIR/archive/app-bundles" -maxdepth 1 -type d -name 'installed-*.bundle-backup' -print | sort | tail -1)
fi
[[ -n "$BACKUP_APP" && -d "$BACKUP_APP" ]] || { echo "No rollback backup found" >&2; exit 1; }
"$PROJECT_DIR/scripts/install_local.sh" "$BACKUP_APP"
echo "Rolled back from: $BACKUP_APP"
