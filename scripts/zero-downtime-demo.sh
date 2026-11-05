#!/usr/bin/env bash
# Proof of zero downtime: hammer the public port while a deploy (or rollback) runs, then count failures.
#   scripts/zero-downtime-demo.sh deploy <tag>
#   scripts/zero-downtime-demo.sh rollback
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PORT="$(grep -E '^WEB_PORT=' .env 2>/dev/null | cut -d= -f2 | head -n 1)"; PORT="${PORT:-80}"
action="${1:?usage: zero-downtime-demo.sh deploy <tag> | rollback}"
out="$(mktemp)"

echo "load: GET /api/health and GET / every ~50ms on port $PORT"
(
  while :; do
    r="$(curl -s -m 3 -w ' HTTP%{http_code}' "http://localhost:$PORT/api/health" || echo ' HTTP000')"
    echo "api $r"
    c="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://localhost:$PORT/" || echo 000)"
    echo "web HTTP$c"
    sleep 0.05
  done
) > "$out" &
loadpid=$!
sleep 2

case "$action" in
  deploy)   scripts/deploy.sh "${2:?tag}" ;;
  rollback) scripts/rollback.sh ;;
  *) kill $loadpid; echo "unknown action"; exit 2 ;;
esac
rc=$?

sleep 3
kill $loadpid 2>/dev/null; wait $loadpid 2>/dev/null

total=$(wc -l < "$out")
ok=$(grep -c 'HTTP200' "$out")
echo
echo "================ RESULT ($action, exit code $rc) ================"
echo "requests sent:   $total"
echo "HTTP 200:        $ok"
echo "FAILED:          $((total - ok))"
echo "versions served by /api/health during the run:"
grep -o '"version":"[^"]*"' "$out" | sort | uniq -c
rm -f "$out"
[ $((total - ok)) -eq 0 ] && [ $rc -eq 0 ]
