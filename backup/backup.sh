#!/usr/bin/env bash
# Dump MongoDB -> compress -> encrypt with age (public key only) -> ship off-site.
# The private key is NOT available here, so a compromised backup host cannot read old backups.
set -euo pipefail
umask 077

: "${MONGO_APP_DB:?}" "${MONGO_APP_USER:?}" "${MONGO_APP_PASSWORD:?}" "${AGE_RECIPIENT:?}"
MONGO_HOST="${MONGO_HOST:-mongo}"
OFFSITE_DIR="${OFFSITE_DIR:-/offsite}"        # clearly-labelled second location (simulated off-provider)
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

log() { echo "$(date -u +%FT%TZ) backup: $*"; }

ts="$(date -u +%Y%m%dT%H%M%SZ)"
name="studyuk-${ts}.archive.gz.age"
mkdir -p "$OFFSITE_DIR"
part="$OFFSITE_DIR/.${name}.part"
cfg="$(mktemp)"; trap 'rm -f "$cfg" "$part"' EXIT

# credentials go in a config file, not on the command line
cat > "$cfg" <<EOF
uri: mongodb://${MONGO_APP_USER}@${MONGO_HOST}:27017/${MONGO_APP_DB}?authSource=${MONGO_APP_DB}
password: ${MONGO_APP_PASSWORD}
EOF

start=$(date +%s)
log "dumping ${MONGO_APP_DB}"
mongodump --config "$cfg" --archive --gzip 2>/tmp/mongodump.log \
  | age -r "$AGE_RECIPIENT" > "$part"
[ -s "$part" ] || { log "ERROR: empty backup"; exit 1; }

mv "$part" "$OFFSITE_DIR/$name"                # atomic: no half-written files visible
size=$(wc -c < "$OFFSITE_DIR/$name")
log "wrote $OFFSITE_DIR/$name (${size} bytes, $(( $(date +%s) - start ))s)"

# optional second off-provider copy to an S3-compatible bucket (Cloudflare R2 / Backblaze B2)
if [ -n "${RCLONE_REMOTE:-}" ]; then
  # The VM key is write-only: it may not read or list, so rclone must not HEAD/list the destination
  # first (that was the 401). File names are unique timestamps, so skipping the check is safe.
  rclone copyto --no-check-dest --no-check-bucket "$OFFSITE_DIR/$name" "${RCLONE_REMOTE%/}/$name"
  log "uploaded to ${RCLONE_REMOTE}"
fi

# retention
find "$OFFSITE_DIR" -name 'studyuk-*.age' -mtime +"$RETENTION_DAYS" -delete
log "done"
