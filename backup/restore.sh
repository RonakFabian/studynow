#!/usr/bin/env bash
# Restore the newest (or a given) encrypted backup into MongoDB.
# Usage: restore.sh [backup-file]      (needs the age PRIVATE key at $AGE_IDENTITY)
set -euo pipefail
umask 077

: "${MONGO_APP_DB:?}" "${MONGO_APP_USER:?}" "${MONGO_APP_PASSWORD:?}"
MONGO_HOST="${MONGO_HOST:-mongo}"
OFFSITE_DIR="${OFFSITE_DIR:-/offsite}"
AGE_IDENTITY="${AGE_IDENTITY:-/run/secrets/age.key}"

log() { echo "$(date -u +%FT%TZ) restore: $*"; }

[ -r "$AGE_IDENTITY" ] || { log "ERROR: private key not found at $AGE_IDENTITY"; exit 1; }

cfg="$(mktemp)"; tmpdir="$(mktemp -d)"; trap 'rm -rf "$cfg" "$tmpdir"' EXIT

if [ -n "${1:-}" ]; then
  file="$1"                                              # an explicit local file
elif [ "${RESTORE_SOURCE:-local}" = remote ]; then
  # restore from the off-provider bucket (what you need if the whole VM/provider is gone)
  [ -n "${RCLONE_REMOTE:-}" ] || { log "ERROR: RESTORE_SOURCE=remote needs RCLONE_REMOTE"; exit 1; }
  latest="$(rclone lsf "$RCLONE_REMOTE" --files-only | grep -E '^studyuk-.*\.age$' | sort | tail -n 1)"
  [ -n "$latest" ] || { log "ERROR: no backups found in $RCLONE_REMOTE"; exit 1; }
  log "downloading $latest from $RCLONE_REMOTE"
  rclone copyto "${RCLONE_REMOTE%/}/$latest" "$tmpdir/$latest"
  file="$tmpdir/$latest"
else
  file="$(ls -1 "$OFFSITE_DIR"/studyuk-*.age 2>/dev/null | sort | tail -n 1)"   # newest local copy
fi
[ -n "$file" ] && [ -r "$file" ] || { log "ERROR: no backup file found"; exit 1; }

cat > "$cfg" <<EOF
uri: mongodb://${MONGO_APP_USER}@${MONGO_HOST}:27017/${MONGO_APP_DB}?authSource=${MONGO_APP_DB}
password: ${MONGO_APP_PASSWORD}
EOF

log "restoring from $file"
start=$(date +%s)
age -d -i "$AGE_IDENTITY" "$file" \
  | mongorestore --config "$cfg" --archive --gzip --drop --nsInclude "${MONGO_APP_DB}.*"
log "done in $(( $(date +%s) - start ))s"
