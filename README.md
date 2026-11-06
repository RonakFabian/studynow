# StudyUK

Small study-platform demo: React frontend, Express API, MongoDB (with auth), served through nginx.

**On call? Start with the [runbook](RUNBOOK.md)**: deploy, roll back, restore, and the "site is down at 2am" checklist.

```
Browser → nginx (:80) ─┬─ /     → React build
                       └─ /api  → Express :3000 → MongoDB :27017 (internal only)
```

## Run

```bash
cp .env.example .env      # then replace every CHANGE_ME (openssl rand -hex 16)
bash scripts/deploy.sh v1   # builds the images and starts everything (first deploy goes to "blue")
```

Open http://localhost (or the VM's IP). Register an account, then log in to see the courses.

## MongoDB security

- Started with authentication on (`MONGO_INITDB_ROOT_*` makes mongod require auth).
- `mongo/init-app-user.sh` creates `MONGO_APP_USER` with `readWrite` on the app database only. The API never uses the root account.
- MongoDB and the API publish no ports; only nginx is reachable from outside.
- The init script runs once, on an empty volume. To re-run it: `docker compose down -v` (this deletes the data).

## API

| Method | Path | Auth |
|---|---|---|
| POST | `/api/auth/register` | no |
| POST | `/api/auth/login` | no |
| GET | `/api/courses` | Bearer token |
| GET | `/api/health` | no |

## Deploy, rollback (zero downtime)

```
Browser → gateway (nginx :80) ─┬─ /     → web-<live colour>
                               └─ /api  → api-<live colour> → mongo
```

Two colours, **blue** and **green**; each is one `api` + one `web` container. Only one is live. `deploy/state.env` (not committed) records which colour is live and which tag each runs.

```bash
bash scripts/deploy.sh <tag>      # e.g. a git short sha; builds images, deploys to the idle colour
bash scripts/rollback.sh          # instant switch back to the previous colour
bash scripts/start.sh             # bring the stack up from recorded state (after reboot / restore)
```

What `deploy.sh` does: start the idle colour on the new version → wait for its Docker health checks → `nginx -t` + graceful `nginx -s reload` to switch (in-flight requests finish on the old colour) → smoke-test `/api/health` through the public port for the new version → if that fails, **automatic rollback**. If the health gate fails, traffic is never switched and the live colour is untouched. The previous colour keeps running, so rollback needs no rebuild.

Rolling back a bad release: `bash scripts/rollback.sh`. (If a deploy itself failed the health gate, there is nothing to roll back - the old version is still live.) The API handles `SIGTERM` gracefully (stops accepting, finishes in-flight requests, exits).

Proof of zero downtime - hammer the public port while deploying:

```bash
bash scripts/zero-downtime-demo.sh deploy v5
bash scripts/zero-downtime-demo.sh rollback
```

Measured locally (2026-11-05; ~50 ms request loop on `/api/health` and `/`):

| Test | Requests | Failed |
|---|---|---|
| Deploy v1 → v2 (blue → green) | 201 | **0** |
| Rollback v2 → v1 | 92 | **0** |
| Deploy of a deliberately crashing release (health gate aborted, never switched) | 528 | **0** |
| Clean deploy v4 afterwards | 202 | **0** |

Also measured on the real VM (DigitalOcean droplet, 2 GB), requests sent from a laptop to the public IP over the internet while the VM switched colours twice (rollback, then forward again): **35 requests, 35 HTTP 200, 0 failed**, and `/api/health` showed the version flip `9840af0 → 66d7bcd → 9840af0` ([evidence](docs/zero-downtime-vm-evidence.txt)). Each request takes ~0.4 s over the internet, so this run sampled about 2-3 requests/s - far coarser than the local 50 ms loop above.

Limits: a user who already has the old frontend open keeps working (API is backwards compatible); there are no database migrations in this app, so a schema change would need an expand/contract approach.

## CI/CD (GitHub Actions)

`.github/workflows/ci-cd.yml`, on every push and pull request:

1. **backend**: `npm ci`, ESLint, integration tests (`node --test`) against a MongoDB service container.
2. **frontend**: `npm ci`, ESLint, production build.
3. **images** (push to `main` only, after 1 and 2 pass): build both images and push them to GHCR, tagged with the 7-char commit sha.
4. **deploy** (push to `main`, after 3): SSH to the VM, ship the runtime files (`docker-compose.yml`, `scripts/`, `gateway/`, `mongo/`, `backup/`) with `tar`, and run `scripts/deploy.sh <sha>` with `BUILD_LOCAL=0`: the VM **pulls the images from GHCR** and does the blue/green zero-downtime deploy above. There is no git checkout or build on the VM. A failing health gate or smoke test leaves the live version untouched (or rolls back automatically).

The deploy job is **off until the VM exists**: it only runs when the repo variable `DEPLOY_ENABLED` is `true`. Locally the same checks run with `npm run lint && npm test` (set `MONGO_URI` to a throwaway MongoDB).

### One-time VM setup

1. Ubuntu 24.04 VM (2 GB RAM: two colours run side by side), SSH key login, firewall open on 22/80/443 only.
2. Install Docker + the compose plugin and create `/opt/studyuk` owned by the deploy user (no git or source checkout needed; the pipeline ships the runtime files).
3. Create `/opt/studyuk/.env` from `.env.example` with real secrets, and put the age **public** key in `AGE_RECIPIENT` (the private key never needs to be on the VM, except while restoring).
4. Create a deploy SSH key pair; add the public key to the VM user's `authorized_keys`.
5. In GitHub (Settings → Secrets and variables → Actions), create an Environment `production` and add secrets `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS` (output of `ssh-keyscan <host>`), then the repository variable `DEPLOY_ENABLED=true`. For off-provider backups also add the environment secrets `B2_BUCKET`, `B2_KEY_ID`, `B2_APP_KEY` (a Backblaze key restricted to that bucket with **list + write only**); each deploy writes them to `/opt/studyuk/rclone.env` (mode 600) on the VM, where the hourly backup container reads them.
6. Make the GHCR packages readable by the VM (the workflow logs the VM in with the job's short-lived token for each deploy).

## Monitoring and alerting

Two checks, both alert to Discord. Both run from outside the VM, so they still work if the VM is down.

**Uptime: UptimeRobot** (free plan, every 5 minutes). A keyword monitor on `http://<vm-ip>/api/health` that alerts when `"db":true` is missing, so it fires both when the site is unreachable and when the app is up but cannot reach MongoDB.

**Health and backup freshness: `.github/workflows/monitor.yml`**, started by hand with **Run workflow**:

1. **Health:** `GET $HEALTH_URL` (3 attempts) must return 200 with `"db":true`.
2. **Backup freshness:** the bucket must hold a `studyuk-*.age` file newer than 90 minutes (hourly backups plus one missed run). This is what protects the 1 h RPO.

A failure posts to Discord (`DISCORD_WEBHOOK_URL`) with the reason and a link to the run. Setup: repository variables `HEALTH_URL`, `B2_BUCKET_NAME`; repository secrets `DISCORD_WEBHOOK_URL`, `B2_MONITOR_KEY_ID`, `B2_MONITOR_APP_KEY` (a read-only bucket key). The manual run has "simulate failure" boxes to test each alert.

**Why UptimeRobot and not only a GitHub schedule:** the workflow also has a 5-minute `schedule:` trigger, but GitHub never started a single scheduled run for this repo (checked through the Actions API, over several hours, and again after moving the cron off the busy :00/:05 minutes), while manual runs worked. GitHub documents scheduled runs as best-effort, so uptime alerting uses a dedicated pinger. Known gap: nothing alerts on a schedule if the backup container dies, so the freshness check has to be run by hand (see the runbook). Prometheus/Grafana was not built (stretch goal).

## Backups

- `backup` service runs `backup/backup.sh` every hour (`BACKUP_INTERVAL_SECONDS`): `mongodump` (as the least-privilege app user) → gzip → **age** encryption → `./offsite/` (a clearly-labelled second location simulating off-provider). Files older than `BACKUP_RETENTION_DAYS` are deleted.
- The backup container only holds the age **public** key (`AGE_RECIPIENT` in `.env`). The **private** key lives in `secrets/age.key` (gitignored) and is only mounted into the manual `restore` service. Store a copy of it somewhere else (password manager) - without it the backups are unreadable.
- Second copy to a Backblaze B2 bucket (off the VM provider) via rclone. In production the deploy job writes `rclone.env` from GitHub secrets (see CI/CD). Locally, create a gitignored `rclone.env` with `RCLONE_REMOTE=b2:bucket`, `RCLONE_CONFIG_B2_TYPE=b2`, `RCLONE_CONFIG_B2_ACCOUNT=<keyID>`, `RCLONE_CONFIG_B2_KEY=<applicationKey>`. The VM's key can only list and write, so a compromised VM cannot read or delete backups. Restore from the bucket needs a separate read key on your laptop: `RESTORE_SOURCE=remote docker compose run --rm restore`. Verified against the real bucket (see the VM drill below).
- Manual backup: `docker compose run --rm --no-deps backup backup.sh`
- Generate a key pair: `docker run --rm --entrypoint age-keygen studynow-backup > secrets/age.key` (put the printed public key in `.env` as `AGE_RECIPIENT`).

## Restore

```bash
docker compose stop api web backup
docker compose run --rm restore                 # newest backup in ./offsite
docker compose run --rm restore restore.sh /offsite/studyuk-<timestamp>.archive.gz.age   # a specific one
docker compose up -d
```

If the database volume is gone, start only Mongo first (`docker compose up -d mongo`), restore, then `docker compose up -d`.

## Restore drill (evidence)

`scripts/restore-drill.ps1` does the whole drill and prints the result; the full transcript from the run is in [docs/restore-drill-evidence.txt](docs/restore-drill-evidence.txt).

Steps: seed data → encrypted backup → add more data → **destroy all containers and the MongoDB volume** → empty Mongo → restore from the encrypted backup → start app → wait for `/api/health` → verify via login.

Measured (local Docker Desktop, 2026-11-05):

| Metric | Result | Notes |
|---|---|---|
| **RTO** | **28.7 s** | From the moment of destruction to `/api/health` OK (includes Mongo init, restore, starting the live colour and gateway). Images were already built/cached; excludes human detection and decision time. A first run on the older single-stack layout measured 17.7 s. |
| **RPO** (this drill) | **21 s** | Time between the last backup and the disaster. The user and course created in that window were lost, as expected. |
| **RPO** (design, worst case) | **1 h** | Hourly backups. Meets the 1 h target only if every hourly run succeeds - the `monitor` workflow alerts Discord if no backup newer than 90 min is in the bucket. |

Restored state matched the backup exactly (5 users / 9 courses; the 6th user and 10th course, created after the backup, were gone), and a pre-backup user could log in and see their own course. The evidence file has Docker's progress noise filtered out.

### Drill on the real VM, restoring from the off-provider bucket

`scripts/restore-drill.sh` (run on the VM) registers user A, takes a backup that is uploaded to Backblaze B2, registers user B, then destroys all containers, the MongoDB volume **and the local backup copies**. It restores the newest backup **downloaded from the bucket**, decrypts it, starts the app and checks that A can log in and B cannot. The age private key and the read-only bucket key are placed on the VM only for the drill and removed by the script on exit ([full transcript](docs/restore-drill-vm-evidence.txt)).

| Metric | Result (2026-11-06, DigitalOcean 2 GB droplet) |
|---|---|
| **RTO** | **42 s**: disaster to `/api/health` OK, including Mongo init, bucket download, decrypt, restore and starting the app |
| **RPO** (this drill) | **2 s**: user B, created after the backup, was lost; user A survived |
| **RPO** (design) | **1 h**, only if every hourly backup succeeds |

The first attempt restored the data but the gateway then crashed: `active.conf` was mode 600 because of a `umask 077` in my SSH session, and nginx runs as another user. The drill found it; `_common.sh` now makes the file 644. The 42 s figure is from the second, clean run. RTO excludes human detection and decision time, and this drill restores onto the same VM; a fresh-VM rebuild (new host, Docker install, deploy, then restore) is slower and has not been timed.
