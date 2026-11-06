# Runbook

Everything runs on one VM in Docker Compose.

- Log in: `ssh deploy@<vm-ip>` (the address is in the DigitalOcean panel and the `SSH_HOST` GitHub secret)
- App folder: `/opt/studyuk`
- Alerts go to the Discord channel. UptimeRobot posts when the site or database is down. The backup check is the `monitor` workflow, which you start by hand (GitHub Actions → monitor → Run workflow); check it at least daily.
- Passwords and keys are in the password manager.

## Deploy

Push to `main`. GitHub Actions runs the tests, builds the images and deploys. It starts the new version next to the old one, switches over only when the new one is healthy, and rolls back by itself if the check after the switch fails.

Check it worked:

```bash
curl -s http://<vm-ip>/api/health
```

You want `"status":"ok"` and the new commit in `version`.

Deploy by hand (on the VM), using the 7-character commit id:

```bash
cd /opt/studyuk
BUILD_LOCAL=0 bash scripts/deploy.sh <commit-id>
```

## Roll back

A bad release is live and you want the old one back:

```bash
cd /opt/studyuk
bash scripts/rollback.sh
curl -s http://127.0.0.1/api/health
```

The old version should show in `version`. It takes a second because the old version is still running.

If it says there is no previous version, the last deploy never went live. Nothing to roll back.

## Restore the database

This replaces the current data with the last backup. Use it when data is lost or damaged, not for a bad release (that's a rollback).

1. **Get both keys from the password manager** and put them on the VM. Log in first with `ssh deploy@<vm-ip>`, then:
   - The age private key. Paste the whole entry, including the comment lines:
     ```bash
     cd /opt/studyuk
     mkdir -p secrets
     (umask 077; nano secrets/age.key)
     ```
   - The read-only bucket key (`restore-read`). Paste these four lines, with the key ID and key filled in:
     ```bash
     (umask 077; nano restore.env)
     ```
     ```
     RCLONE_REMOTE=b2:data-dump-study-uk
     RCLONE_CONFIG_B2_TYPE=b2
     RCLONE_CONFIG_B2_ACCOUNT=<keyID>
     RCLONE_CONFIG_B2_KEY=<applicationKey>
     ```
2. Start Mongo and restore the newest backup from the bucket:
   ```bash
   docker compose --env-file .env --env-file deploy/state.env up -d mongo
   export RESTORE_SOURCE=remote
   docker compose --env-file .env --env-file deploy/state.env run -T --rm restore
   ```
3. Start the app and check it:
   ```bash
   bash scripts/start.sh
   curl -s http://127.0.0.1/api/health
   ```
4. Delete the keys from the VM:
   ```bash
   rm -f secrets/age.key restore.env
   ```

If the whole VM is gone, make a new one, install Docker, put the `.env` back from the password manager, deploy from GitHub, then follow the steps above.

## The site is down

1. **Is it really down?**
   ```bash
   curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://<vm-ip>/api/health
   ```
   `200` is fine. `000` means no answer. `503` means the app is up but can't reach the database.
2. **Can you log in?** `ssh deploy@<vm-ip>`. If not, open the DigitalOcean panel, check the droplet is on, and reboot it. After a reboot run `cd /opt/studyuk && bash scripts/start.sh`.
3. **What's running?** `docker ps -a`. You should see gateway, mongo, an api, a web and backup, all `Up` or `healthy`.
4. **Fix what's broken:**
   - Gateway keeps restarting: `docker logs --tail 30 studyuk-gateway-1`. If it says `Permission denied`, run `chmod 644 deploy/gateway/active.conf && docker restart studyuk-gateway-1`.
   - App unhealthy after a deploy: roll back (above).
   - Database down: `docker logs --tail 50 studyuk-mongo-1` and `df -h`. A full disk is the usual cause. Free space with `docker system prune -f`, then start Mongo again.
   - Everything stopped: `bash scripts/start.sh`.
   - Data is missing or wrong: restore (above).
5. **Check:** the health URL again, and log in on the site.
6. **Write down** what happened and when. Targets: back within 4 hours, lose at most 1 hour of data.

**Backup check failed (`:warning:` in Discord after you run the monitor workflow):** on the VM run `docker compose --env-file .env --env-file deploy/state.env logs --tail 30 backup`.

- A 401 or 403 error means the bucket key changed. Fix the GitHub secrets and re-run the deploy.
- No log lines means the container is down. Run `bash scripts/start.sh`.
