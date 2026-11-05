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
file="${1:-$(ls -1 "$OFFSITE_DIR"/studyuk-*.age 2>/dev/null | sort | tail -n 1)}"
[ -n "$file" ] && [ -r "$file" ] || { log "ERROR: no backup file found"; exit 1; }

cfg="$(mktemp)"; trap 'rm -f "$cfg"' EXIT
cat > "$cfg" <<EOF
uri: mongodb://${MONGO_APP_USER}@${MONGO_HOST}:27017/${MONGO_APP_DB}?authSource=${MONGO_APP_DB}
password: ${MONGO_APP_PASSWORD}
EOF

log "restoring from $file"
start=$(date +%s)
age -d -i "$AGE_IDENTITY" "$file" \
  | mongorestore --config "$cfg" --archive --gzip --drop --nsInclude "${MONGO_APP_DB}.*"
log "done in $(( $(date +%s) - start ))s"
