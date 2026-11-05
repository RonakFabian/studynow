#!/usr/bin/env bash
# Bring the stack up using the recorded live colour (after a reboot, or after restoring a wiped host/volume).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[ "$ACTIVE" != none ] || die "no deployment recorded - run scripts/deploy.sh <tag> first"
log "starting mongo + $ACTIVE colour + gateway + backup"
dc up -d mongo >/dev/null 2>&1
dc up -d --no-deps "api-$ACTIVE" "web-$ACTIVE" >/dev/null 2>&1
wait_healthy "api-$ACTIVE" && wait_healthy "web-$ACTIVE" || die "$ACTIVE did not become healthy"
switch_gateway "$ACTIVE"
dc up -d backup >/dev/null 2>&1 || true
log "up: $ACTIVE is live"
