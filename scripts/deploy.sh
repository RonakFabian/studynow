#!/usr/bin/env bash
# Zero-downtime blue/green deploy.
#   scripts/deploy.sh <tag>            build images locally (default) and deploy
#   BUILD_LOCAL=0 scripts/deploy.sh <tag>   pull images from a registry (set API_IMAGE / WEB_IMAGE)
#
# 1. start the IDLE colour with the new version      (users still on the old colour)
# 2. wait for its health checks                      (bad release -> abort, nobody ever sees it)
# 3. graceful nginx reload to the new colour         (in-flight requests finish on the old one)
# 4. smoke test through the public port              (fails -> automatic rollback)
# The old colour keeps running, so rollback is instant.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TAG="${1:?usage: scripts/deploy.sh <tag>   (e.g. a git short sha)}"
case "$ACTIVE" in blue) TARGET=green ;; *) TARGET=blue ;; esac    # first deploy -> blue
log "live colour: $ACTIVE | deploying tag '$TAG' to idle colour: $TARGET"

if [ "${BUILD_LOCAL:-1}" = 1 ]; then
  log "building images"
  docker build -q -t "$API_IMAGE:$TAG" backend
  docker build -q -t "$WEB_IMAGE:$TAG" frontend
fi

if [ "$TARGET" = blue ]; then BLUE_TAG="$TAG"; else GREEN_TAG="$TAG"; fi
save_state
[ "${BUILD_LOCAL:-1}" = 1 ] || dc pull "api-$TARGET" "web-$TARGET"

dc up -d mongo >/dev/null 2>&1
log "starting api-$TARGET and web-$TARGET"
dc up -d --no-deps --force-recreate "api-$TARGET" "web-$TARGET" >/dev/null 2>&1

HT="${HEALTH_TIMEOUT:-90}"
if ! { wait_healthy "api-$TARGET" "$HT" && wait_healthy "web-$TARGET" "$HT"; }; then
  log "HEALTH GATE FAILED - traffic was NOT switched; '$ACTIVE' is still live"
  dc logs --tail 20 "api-$TARGET" || true
  dc stop "api-$TARGET" "web-$TARGET" >/dev/null 2>&1 || true
  PREVIOUS=none; save_state    # the idle colour was overwritten by the failed release: nothing to roll back to
  exit 1
fi
log "$TARGET is healthy"

PREVIOUS_OLD="$PREVIOUS"
switch_gateway "$TARGET"
PREVIOUS="$ACTIVE"; ACTIVE="$TARGET"; save_state
dc up -d backup >/dev/null 2>&1 || true
log "switched: $PREVIOUS -> $ACTIVE"

# smoke test through the real public entry point
PORT="$(public_port)"
ok=0
for _ in 1 2 3 4 5; do
  if curl -fsS -m 3 "http://localhost:$PORT/api/health" | grep -q "\"version\":\"$TAG\""; then ok=1; break; fi
  sleep 1
done
if [ "$ok" != 1 ]; then
  log "SMOKE TEST FAILED - rolling back automatically"
  "$(dirname "${BASH_SOURCE[0]}")/rollback.sh"
  exit 1
fi
log "DEPLOY OK: '$TAG' is live on $ACTIVE (previous: $PREVIOUS kept running for rollback)"
