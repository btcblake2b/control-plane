# Control Plane — operator and developer guide

**Outbound** provisioning registry for self-hosted Lightning nodes
(bitcoin-blake2b). It does not hold funds, does not sign, and never accesses
users' servers: it stores only pseudonymous data (bridge pubkey, relay,
alias, version, timestamp) and token/secret hashes.

## Requirements and build

- Dart SDK 3.3+ (runtime) — or `dart compile exe` for the binary:
  ```bash
  cd server
  dart pub get
  dart analyze && dart test          # dev gates
  dart compile exe bin/server.dart -o tlw-control-plane
  dart compile exe bin/admin.dart    -o tlw-admin
  ```
- SQLite (system `libsqlite3`, present on Ubuntu).

## Configuration (environment variables)

| Variable | Default | Notes |
|---|---|---|
| `TLW_CP_BIND` | `127.0.0.1` | Loopback: TLS terminated by a reverse proxy |
| `TLW_CP_PORT` | `8787` | |
| `TLW_CP_DB` | `data/control.db` | Created automatically (WAL) |
| `TLW_CP_TRUST_PROXY` | `0` | `1` = trust `X-Forwarded-For` (ONLY behind a proxy that rewrites the header) |
| `TLW_CP_TOKEN_TTL_HOURS` | `24` | Registration token validity |

## Deploy (example)

```ini
# /etc/systemd/system/tlw-control-plane.service
[Unit]
Description=TLW Control Plane
After=network-online.target

[Service]
User=tlwcp
WorkingDirectory=/opt/tlw-cp
ExecStart=/opt/tlw-cp/tlw-control-plane
Environment=TLW_CP_DB=/opt/tlw-cp/data/control.db
Environment=TLW_CP_TRUST_PROXY=1
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```caddyfile
# Caddy in front (TLS + X-Forwarded-For toward 127.0.0.1:8787)
cp.example.org {
    reverse_proxy 127.0.0.1:8787
}
```

⚠️ If the CP is exposed **directly** (without a proxy): keep `TLW_CP_TRUST_PROXY=0`.

## API v1

Uniform errors: `{"error":{"code":"…","message":"…"}}`. Body ≤ 8KB. Timestamps ISO8601 UTC.

### `POST /v1/register`
```json
{ "token": "<64hex>", "bridgePubkey": "<64hex>", "relay": "wss://…", "alias": "home", "version": "0.3.0" }
```
→ `201 {"nodeId":"<32hex>","nodeSecret":"<64hex>","createdAt":"…"}` (the secret is shown **once only**).
The token is consumed **only on success** (a 409 does not burn it).

### `GET /v1/nodes/<id>` — header `Authorization: Bearer <nodeSecret>`
→ `200 {"id","bridgePubkey","relay","alias","version","createdAt","rotatedAt"}`

### `DELETE /v1/nodes/<id>` — Bearer
→ `204` (immediate hard delete; second call → `404`)

### `POST /v1/nodes/<id>/rotate-secret` — Bearer (current secret)
→ `200 {"nodeSecret":"<new>"}` (the old one is invalidated immediately)

| HTTP | Code | When |
|---|---|---|
| 400 | `INVALID_REQUEST` | invalid payload/JSON |
| 401 | `INVALID_TOKEN` / `UNAUTHORIZED` | wrong registration token or Bearer |
| 404 | `NOT_FOUND` | nonexistent id / unknown route |
| 409 | `ALREADY_REGISTERED` | pubkey already registered (token not consumed) |
| 410 | `TOKEN_EXPIRED` / `TOKEN_USED` | expired or already-used token |
| 429 | `RATE_LIMITED` | too many attempts (`Retry-After` in seconds) |

Rate-limit (in-memory, resets on restart): register 20 burst / 10 per hour per IP;
general endpoints 120 burst / 60 per minute per IP.

## Admin CLI (`admin`, operator only, with shell access)

**There is no HTTP administration endpoint**: issuing tokens requires
server access. Whoever has SSH to the CP is, by definition, the operator.

```bash
tlw-admin token create --note "for Mario" --ttl 24h  # prints the token ONCE
tlw-admin token list [--all]                         # active (default) or all
tlw-admin token purge                                # expired/used >7 days
tlw-admin node list
tlw-admin node delete <id> [--yes]                   # recovery / record removal
```

## Backup

The database is a SQLite file (`data/control.db` + `-wal`). Backup with the
service stopped (or `sqlite3 control.db ".backup backup.db"`). Data is pseudonymous and
rebuildable: a user can always re-register (recovery).

## Development

- Conventions: `dart analyze` 0 issues, `dart test` green, manual models
  (no codegen), `// WHY` comments on non-obvious choices.
- Tests: `server/test/` (auth, db, end-to-end api on an ephemeral port, admin CLI).
- Project shared memory: `btc-blake2b-wallet/docs/ai-memory/` (ADRs in `DECISIONS.md`).
