# StudyUK runbook

Written for an engineer who did not build this. Everything runs on one VM, in Docker Compose, in `/opt/studyuk`.

```
Browser -> gateway (nginx :80) -> blue or green (api + web) -> mongo
                                   backup container -> encrypted dump -> ./offsite + Backblaze B2 bucket
GitHub Actions: ci-cd (test, build, deploy)   monitor (health + backup freshness -> Discord)
```

| Thing | Where |
|---|---|
| VM | DigitalOcean droplet, `deploy@167.99.206.115`, app in `/opt/studyuk` (DigitalOcean console works if SSH is down) |
| Source / pipeline | GitHub repo, `.github/workflows/ci-cd.yml` and `monitor.yml` |
| Images | `ghcr.io/ronakfabian/studyuk-api` and `-web`, tagged with the 7-char commit sha |
| Backups | `./offsite/` on the VM (7 days) and the Backblaze B2 bucket `data-dump-study-uk` (hourly, never deleted by the VM) |
| Alerts | Discord channel, from the `monitor` workflow |

## Secrets: where each one lives

| Secret | Where | Not in |
|---|---|---|
| `/opt/studyuk/.env` (Mongo passwords, `JWT_SECRET`, age **public** key) | VM only, mode 600 | git, GitHub |
| B2 **write-only** key | GitHub `production` environment, written to `/opt/studyuk/rclone.env` (mode 600) on every deploy | git |
| B2 **read** key (`restore-read`) | Password manager; also GitHub repo secrets `B2_MONITOR_*` for the freshness check | git, VM (only while restoring) |
| age **private** key | Password manager / laptop `secrets/age.key` | git, GitHub, VM (only while restoring) |
| SSH deploy key, Discord webhook | GitHub secrets | git |

`/opt/studyuk/.env` is **not backed up**. Keep a copy in the password manager, otherwise a rebuilt VM has new passwords (data restores fine, because the app user is created from the new `.env`; users just have to log in again if `JWT_SECRET` changed).

## Deploy

Normal path: merge or push to `main`. The pipeline runs lint and tests, builds both images, pushes them to GHCR, then deploys over SSH with `scripts/deploy.sh <sha>`:

1. Starts the idle colour (blue or green) on the new image.
2. Waits for its health checks to pass (the live colour is untouched until then).
3. Switches the gateway (`nginx -t`, then a graceful reload), then smoke-tests `/api/health` for the new version.
4. If the smoke test fails, it rolls back automatically. If the health gate fails, traffic never moved.

Manual deploy of an existing image (on the VM):

```bash
cd /opt/studyuk
BUILD_LOCAL=0 bash scripts/deploy.sh <7-char-sha>
```

Check what is live: `cat deploy/state.env` (`ACTIVE`, `BLUE_TAG`, `GREEN_TAG`) and `curl -s http://127.0.0.1/api/health` (shows the version).

## Roll back

On the VM, instant (the previous colour is still running):

```bash
cd /opt/studyuk
bash scripts/rollback.sh
curl -s http://127.0.0.1/api/health      # version should be the old one
```

If `PREVIOUS=none` in `deploy/state.env` there is nothing to switch to (the last deploy failed its health gate, so the old version is still live). To go back further, re-run the GitHub Actions deploy of an older commit.

## Restore the database from backup

Destructive: `--drop` replaces the current data with the backup. Use it for data loss or corruption, not for an app bug (that is a rollback).

1. Put the keys on the VM for the duration of the restore (from the password manager, never into git):
   - `scp secrets/age.key deploy@167.99.206.115:/opt/studyuk/secrets/age.key`
   - Create `/opt/studyuk/restore.env`, mode 600, with the **read** key: `RCLONE_REMOTE=b2:data-dump-study-uk`, `RCLONE_CONFIG_B2_TYPE=b2`, `RCLONE_CONFIG_B2_ACCOUNT=<keyID>`, `RCLONE_CONFIG_B2_KEY=<applicationKey>`.
2. Make sure Mongo is up and healthy: `cd /opt/studyuk && docker compose --env-file .env --env-file deploy/state.env up -d mongo`.
3. Restore the newest backup from the bucket (or add `restore.sh /offsite/<file>` for a specific local one):
   ```bash
   export RESTORE_SOURCE=remote
   docker compose --env-file .env --env-file deploy/state.env run -T --rm restore
   ```
4. Start the app: `bash scripts/start.sh`, then `curl -s http://127.0.0.1/api/health`.
5. **Delete the keys again:** `rm -f secrets/age.key restore.env`.

Whole VM lost: create a new Ubuntu VM, install Docker, make `/opt/studyuk`, put `.env` back from the password manager, update the GitHub secrets `SSH_HOST` / `SSH_KNOWN_HOSTS`, run the `ci-cd` deploy (this also writes `rclone.env`), then do the restore steps above. Not yet timed end to end; the drill only covers the restore on the existing VM.

`scripts/restore-drill.sh` rehearses all of this and prints the measured RTO/RPO. It **destroys the database and the local backups**, so never run it on a system whose data you need.

## "The site is down at 2am" checklist

Alerts: `:rotating_light:` = health check failed, `:warning:` = no backup in the bucket for 90 minutes.

1. **Confirm.** `curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://167.99.206.115/api/health`. `200` = fine (or flapping). `000` = no answer. `503` = the app is up but cannot reach MongoDB.
2. **Can you reach the VM?** `ssh deploy@167.99.206.115`. If not: DigitalOcean control panel -> the droplet -> status, console, **reboot** (everything restarts by itself: containers use `restart: unless-stopped`; then run `bash scripts/start.sh`). If DigitalOcean itself has an incident, see their status page and escalate.
3. **What is running?** `cd /opt/studyuk && docker ps -a`. You should see `gateway`, `mongo`, `api-<colour>`, `web-<colour>` and `backup`, all `healthy` or `Up`.
4. **Pick the symptom:**
   - *Gateway restarting or exited:* `docker logs --tail 30 studyuk-gateway-1`. `Permission denied` on `active.conf` -> `chmod 644 deploy/gateway/active.conf && docker restart studyuk-gateway-1`. Any other error -> fix it, or run `bash scripts/start.sh`.
   - *api container unhealthy:* `docker logs --tail 50 studyuk-api-<colour>-1`. If it started after a deploy, **roll back** (above).
   - *Mongo down or unhealthy:* `docker logs --tail 50 studyuk-mongo-1`; `df -h` (a full disk is the usual cause: free space, e.g. `docker system prune -f`, then `docker compose --env-file .env --env-file deploy/state.env up -d mongo`).
   - *Everything stopped after a reboot:* `bash scripts/start.sh`.
   - *Data missing or corrupt:* restore from backup (above).
5. **Verify** with the health URL and by logging in on the site.
6. **Write down** what happened, the times, and what you changed (the RTO target is 4 h, RPO 1 h).

## Backup alert (`:warning:`)

1. `docker compose --env-file .env --env-file deploy/state.env logs --tail 30 backup` on the VM.
2. `ERROR` from rclone with 401 or 403 = the B2 key was revoked or the secret changed: re-run the `ci-cd` deploy after fixing `B2_KEY_ID` / `B2_APP_KEY` in the `production` environment.
3. No log lines at all = the container is down: `bash scripts/start.sh`.
4. Force a backup now: `docker compose --env-file .env --env-file deploy/state.env run -T --rm --no-deps backup backup.sh`, then check the bucket for a new `.age` file.
5. If the check itself fails with a listing error, the `B2_MONITOR_*` secrets are wrong or the key was deleted.

## Known limits

- HTTP only (no domain yet). The 2 GB VM holds both colours at once.
- The monitor runs on a GitHub 5-minute schedule, which can start late; a failure repeats the alert every run until fixed.
- No tested rebuild of a completely new VM, and no off-VM copy of `.env`.
- Single VM, single region: a provider outage means downtime until a new VM is built and restored.
