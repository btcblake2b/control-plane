# Control Plane — guida operatore e sviluppatore

Registro di provisioning **outbound** per nodi Lightning self-hosted
(bitcoin-blake2b). Non custodisce fondi, non firma, non ha mai accesso ai
server degli utenti: conserva solo dati pseudonimi (pubkey bridge, relay,
alias, versione, timestamp) e gli hash di token/secret.

## Requisiti e build

- Dart SDK 3.3+ (runtime) — oppure `dart compile exe` per il binario:
  ```bash
  cd server
  dart pub get
  dart analyze && dart test          # gate di sviluppo
  dart compile exe bin/server.dart -o tlw-control-plane
  dart compile exe bin/admin.dart    -o tlw-admin
  ```
- SQLite (`libsqlite3` di sistema, presente su Ubuntu).

## Configurazione (variabili d'ambiente)

| Variabile | Default | Note |
|---|---|---|
| `TLW_CP_BIND` | `127.0.0.1` | Loopback: TLS terminato da un reverse proxy |
| `TLW_CP_PORT` | `8787` | |
| `TLW_CP_DB` | `data/control.db` | Creato automaticamente (WAL) |
| `TLW_CP_TRUST_PROXY` | `0` | `1` = fidati di `X-Forwarded-For` (SOLO dietro proxy che riscrive l'header) |
| `TLW_CP_TOKEN_TTL_HOURS` | `24` | Validità dei token di registrazione |

## Deploy (esempio)

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
# Caddy davanti (TLS + X-Forwarded-For verso 127.0.0.1:8787)
cp.example.org {
    reverse_proxy 127.0.0.1:8787
}
```

⚠️ Se il CP è esposto **direttamente** (senza proxy): tenere `TLW_CP_TRUST_PROXY=0`.

## API v1

Errori uniformi: `{"error":{"code":"…","message":"…"}}`. Body ≤ 8KB. Timestamp ISO8601 UTC.

### `POST /v1/register`
```json
{ "token": "<64hex>", "bridgePubkey": "<64hex>", "relay": "wss://…", "alias": "casa", "version": "0.1.0" }
```
→ `201 {"nodeId":"<32hex>","nodeSecret":"<64hex>","createdAt":"…"}` (il secret è mostrato **una volta sola**).
Il token viene consumato **solo su successo** (un 409 non lo brucia).

### `GET /v1/nodes/<id>` — header `Authorization: Bearer <nodeSecret>`
→ `200 {"id","bridgePubkey","relay","alias","version","createdAt","rotatedAt"}`

### `DELETE /v1/nodes/<id>` — Bearer
→ `204` (hard delete immediato; seconda chiamata → `404`)

### `POST /v1/nodes/<id>/rotate-secret` — Bearer (secret corrente)
→ `200 {"nodeSecret":"<nuovo>"}` (il vecchio è invalidato subito)

| HTTP | Codice | Quando |
|---|---|---|
| 400 | `INVALID_REQUEST` | payload/JSON non valido |
| 401 | `INVALID_TOKEN` / `UNAUTHORIZED` | token di registrazione o Bearer errati |
| 404 | `NOT_FOUND` | id inesistente / rotta sconosciuta |
| 409 | `ALREADY_REGISTERED` | pubkey già registrata (token non consumato) |
| 410 | `TOKEN_EXPIRED` / `TOKEN_USED` | token scaduto o già usato |
| 429 | `RATE_LIMITED` | troppi tentativi (`Retry-After` in secondi) |

Rate-limit (in-memory, si azzera al riavvio): register 20 di burst / 10 all'ora per IP;
endpoint generali 120 di burst / 60 al minuto per IP.

## Admin CLI (`admin`, solo operatore con accesso shell)

**Non esiste alcun endpoint HTTP di amministrazione**: emettere token richiede
accesso al server. Chi ha SSH al CP è, per definizione, l'operatore.

```bash
tlw-admin token create --note "per Mario" --ttl 24h   # stampa il token UNA volta
tlw-admin token list [--all]                          # attivi (default) o tutti
tlw-admin token purge                                 # scaduti/usati da >7 giorni
tlw-admin node list
tlw-admin node delete <id> [--yes]                    # recovery / rimozione record
```

## Backup

Il database è un file SQLite (`data/control.db` + `-wal`). Backup a servizio
fermo (o `sqlite3 control.db ".backup backup.db"`). I dati sono pseudonimi e
ricostruibili: un utente può sempre ri-registrarsi (recovery).

## Sviluppo

- Convenzioni: `dart analyze` 0 issue, `dart test` verdi, modelli manuali
  (niente codegen), commenti `// PERCHÉ` sulle scelte non ovvie.
- Test: `server/test/` (auth, db, api end-to-end su porta effimera, admin CLI).
- Memoria condivisa del progetto: `btc-blake2b-wallet/docs/ai-memory/` (ADR in `DECISIONS.md`).
