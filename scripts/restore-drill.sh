#!/usr/bin/env bash
# Restore drill on the real host (run on the VM from /opt/studyuk):
#   user A registered -> backup shipped to the bucket -> user B registered (after the backup, will be lost)
#   -> DISASTER: all containers, the MongoDB volume and the local backup copies are destroyed
#   -> empty Mongo -> newest backup downloaded from the bucket, decrypted, restored -> app up -> verified.
# Needs, only for the duration of the drill (removed on exit unless KEEP_KEYS=1):
#   secrets/age.key  the age PRIVATE key      restore.env  the READ-ONLY bucket key (RCLONE_REMOTE + RCLONE_CONFIG_B2_*)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[ "$ACTIVE" != none ] || die "no deployment recorded - run scripts/deploy.sh <tag> first"
[ -f secrets/age.key ] || die "missing secrets/age.key (the age private key)"
[ -f restore.env ] || die "missing restore.env (read-only bucket key)"
trap '[ "${KEEP_KEYS:-0}" = 1 ] || { rm -f secrets/age.key restore.env; log "removed secrets/age.key and restore.env from this host"; }' EXIT

BASE="http://127.0.0.1:$(public_port)"
JSON='Content-Type: application/json'
stamp="$(date +%s)"
A_EMAIL="drill-a-$stamp@example.com"; B_EMAIL="drill-b-$stamp@example.com"; PW="DrillPass-$stamp"
api() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/auth/$1" -H "$JSON" -d "{\"name\":\"Drill\",\"email\":\"$2\",\"password\":\"$PW\"}"; }

log "1. register user A (will be in the backup)"
[ "$(api register "$A_EMAIL")" = 201 ] || die "could not register user A"

log "2. backup now (dump -> age -> upload to the bucket)"
dc run -T --rm --no-deps backup backup.sh
backup_at="$(date +%s)"
sleep 2

log "3. register user B AFTER the backup (this is the data we expect to lose = RPO)"
[ "$(api register "$B_EMAIL")" = 201 ] || die "could not register user B"

log "4. DISASTER: destroy containers, MongoDB volume and local backup copies"
disaster_at="$(date +%s)"
dc down -v >/dev/null 2>&1
rm -f offsite/studyuk-*.age
if curl -fs -m 3 "$BASE/api/health" >/dev/null; then die "site still answers - disaster did not happen"; fi
log "   site is down; data volume and local backups are gone"

log "5. recover: empty Mongo, then restore the newest backup FROM THE BUCKET"
dc up -d mongo >/dev/null 2>&1
wait_healthy mongo 120 || die "mongo did not become healthy"
export RESTORE_SOURCE=remote
dc run -T --rm restore
log "6. start the app"
bash scripts/start.sh
for ((i = 0; i < 120; i += 2)); do
  curl -fs -m 3 "$BASE/api/health" >/dev/null && break
  sleep 2
done
curl -fs -m 3 "$BASE/api/health" >/dev/null || die "app not healthy after restore"
healthy_at="$(date +%s)"

log "7. verify"
a="$(api login "$A_EMAIL")"; b="$(api login "$B_EMAIL")"
echo "   user A (in backup)   login -> HTTP $a   (expected 200)"
echo "   user B (after backup) login -> HTTP $b   (expected 401: lost, as expected)"
[ "$a" = 200 ] && [ "$b" = 401 ] || die "verification failed"

echo
echo "RESTORE DRILL RESULT ($(date -u +%FT%TZ), host $(hostname))"
echo "  RTO (disaster -> /api/health OK, restored from the bucket): $((healthy_at - disaster_at)) s"
echo "  RPO (this drill, last backup -> disaster):                   $((disaster_at - backup_at)) s"
echo "  Design RPO: 1 h (hourly backups)"
