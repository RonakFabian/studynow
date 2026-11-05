#!/usr/bin/env bash
# Instant rollback: point the gateway back at the previous colour (still running, old image).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[ "$PREVIOUS" != none ] || die "no previous colour recorded - nothing to roll back to"
TARGET="$PREVIOUS"
log "rolling back: $ACTIVE (tag $([ "$ACTIVE" = blue ] && echo "$BLUE_TAG" || echo "$GREEN_TAG")) -> $TARGET (tag $([ "$TARGET" = blue ] && echo "$BLUE_TAG" || echo "$GREEN_TAG"))"

# normally a no-op (already running); starts it if someone stopped it
dc up -d --no-deps "api-$TARGET" "web-$TARGET" >/dev/null 2>&1
wait_healthy "api-$TARGET" && wait_healthy "web-$TARGET" || die "$TARGET is not healthy; not switching"

switch_gateway "$TARGET"
PREVIOUS="$ACTIVE"; ACTIVE="$TARGET"; save_state
log "ROLLED BACK: $ACTIVE is live again (the bad release on $PREVIOUS is left running for debugging)"
