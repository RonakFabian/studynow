#!/usr/bin/env bash
# Shared helpers for deploy.sh / rollback.sh / start.sh. Source it; don't run it.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

STATE=deploy/state.env          # which colour is live + which image tag each colour runs (not committed)
GW_DIR=deploy/gateway           # generated nginx upstream file lives here (not committed)
mkdir -p "$GW_DIR"
[ -f "$STATE" ] || printf 'ACTIVE=none\nPREVIOUS=none\nBLUE_TAG=none\nGREEN_TAG=none\n' > "$STATE"
# shellcheck disable=SC1090
. "$STATE"

export COMPOSE_PROFILES=blue,green
dc() { docker compose --env-file .env --env-file "$STATE" "$@"; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { log "ERROR: $*"; exit 1; }

save_state() {
  printf 'ACTIVE=%s\nPREVIOUS=%s\nBLUE_TAG=%s\nGREEN_TAG=%s\n' "$ACTIVE" "$PREVIOUS" "$BLUE_TAG" "$GREEN_TAG" > "$STATE"
}

# wait_healthy <service> [timeout-seconds]
wait_healthy() {
  local svc="$1" timeout="${2:-90}" id st i
  for ((i = 0; i < timeout; i += 2)); do
    id="$(dc ps -q "$svc" 2>/dev/null | head -n 1)"
    st="$([ -n "$id" ] && docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo none)"
    [ "$st" = healthy ] && return 0
    sleep 2
  done
  return 1
}

# write_upstream <colour>: atomically point the gateway config at one colour
write_upstream() {
  printf 'upstream api_active { server api-%s:3000; }\nupstream web_active { server web-%s:8080; }\n' "$1" "$1" > "$GW_DIR/active.conf.tmp"
  mv "$GW_DIR/active.conf.tmp" "$GW_DIR/active.conf"
}

gateway_running() {
  local id; id="$(dc ps -q gateway 2>/dev/null | head -n 1)"
  [ -n "$id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$id")" = true ]
}

# switch_gateway <colour>: validate the new config, then graceful reload (in-flight requests finish)
switch_gateway() {
  local colour="$1"
  cp -f "$GW_DIR/active.conf" "$GW_DIR/active.conf.bak" 2>/dev/null || true
  write_upstream "$colour"
  if gateway_running; then
    if ! dc exec -T gateway nginx -t >/dev/null 2>&1; then
      [ -f "$GW_DIR/active.conf.bak" ] && mv "$GW_DIR/active.conf.bak" "$GW_DIR/active.conf"
      die "nginx rejected the new config; traffic NOT switched"
    fi
    dc exec -T gateway nginx -s reload >/dev/null 2>&1
  else
    dc up -d gateway >/dev/null 2>&1
    wait_healthy gateway 60 || die "gateway did not become healthy"
  fi
}

public_port() { grep -E '^WEB_PORT=' .env 2>/dev/null | cut -d= -f2 | head -n 1 | grep . || echo 80; }
