#!/usr/bin/env bash
# Runs backup.sh every BACKUP_INTERVAL_SECONDS (default 3600 = hourly, matching a 1h RPO).
interval="${BACKUP_INTERVAL_SECONDS:-3600}"
while true; do
  backup.sh || echo "$(date -u +%FT%TZ) backup: FAILED"
  sleep "$interval"
done
