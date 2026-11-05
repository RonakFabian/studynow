# StudyUK

Small study-platform demo: React frontend, Express API, MongoDB (with auth), served through nginx.

```
Browser → nginx (:80) ─┬─ /     → React build
                       └─ /api  → Express :3000 → MongoDB :27017 (internal only)
```

## Run

```bash
cp .env.example .env      # then replace every CHANGE_ME (openssl rand -hex 16)
docker compose up -d --build
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
