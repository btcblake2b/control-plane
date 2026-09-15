# Revocation, retention and recovery

## Principle

**Revocation is local.** The control plane has no access to users' servers,
so it cannot revoke anything remotely — and it must not. Every action on the
node (allowlist, stop, uninstall) happens on the user's server via the installer.

## Revoking a client (lost phone, decommissioned app)

```bash
./install.sh --revoke-client <CLIENT_PUBKEY>   # removes from the allowlist + restart
```

- **Immediate** effect: that client's URI is no longer authorized by the bridge.
- The client pubkey is shown when the URI is generated (`--genuri`).
- On the control plane side there is nothing to update: the CP does not know the
  clients, only the node (*bridge* pubkey).

## Deleting the node record

| Actor | Command | Effect |
|---|---|---|
| User | `DELETE /v1/nodes/<id>` with Bearer `node_secret` (also via `--status` to check) | **Immediate hard delete** of pseudonymous data |
| Operator (recovery) | `admin node delete <id>` | Hard delete; used when the user lost `node.json` |

After the delete: `GET` → `404`; to re-register you need a **new token**.

## Retention

| Data | Policy | Status |
|---|---|---|
| Expired/used tokens | Purge > **7 days** (`admin token purge`) | Implemented |
| Node records | Until explicit delete (immediate hard delete) | Implemented |
| Inactive nodes | No automatic purge in this phase (heartbeat missing, coming with M-B) | To do (M-B) |
| CP logs | Recommended 30 days, without sensitive contents (logs never contain secrets) | Documented |

## Recovery — practical cases

1. **Lost `node.json` (secret gone)**: `admin node delete <id>` (operator) → new token → `install.sh --register …`. Secrets are never transmitted from the operator to the user.
2. **Suspected secret**: the user runs `--rotate-secret` (old one invalidated immediately).
3. **Expired/reused token**: new token (`admin token create`).
4. **409 conflict on re-registration**: old record still present → delete + new token.

## GDPR (summary)

- Data processed: **pseudonymous** (pubkey, relay, user-chosen alias, version, timestamp) — no PII needed for the service.
- Right to erasure: self-service (DELETE) or request to the operator; deletion is immediate and permanent.
- Minimization: the control plane is opt-in and not required for the wallet or the node to work (the node lives without the CP).
