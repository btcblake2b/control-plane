# Revoca, retention e recovery

## Principio

**La revoca è locale.** Il control plane non ha accesso ai server degli utenti,
quindi non può revocare nulla da remoto — e non deve. Ogni azione sul nodo
(allowlist, stop, uninstall) avviene sul server dell'utente tramite installer.

## Revoca di un client (telefono perso, app dismessa)

```bash
./install.sh --revoke-client <PUBKEY_CLIENT>   # rimuove dall'allowlist + restart
```

- Effetto **immediato**: la URI di quel client non è più autorizzata dal bridge.
- La pubkey del client viene mostrata quando si genera la URI (`--genuri`).
- Lato control plane non c'è nulla da aggiornare: il CP non conosce i client,
  solo il nodo (pubkey del *bridge*).

## Eliminazione del record del nodo

| Attore | Comando | Effetto |
|---|---|---|
| Utente | `DELETE /v1/nodes/<id>` con Bearer `node_secret` (anche via `--status` per verificare) | **Hard delete immediato** dei dati pseudonimi |
| Operatore (recovery) | `admin node delete <id>` | Hard delete; usato quando l'utente ha perso `node.json` |

Dopo il delete: `GET` → `404`; per ri-registrarsi serve un **nuovo token**.

## Retention

| Dato | Politica | Stato |
|---|---|---|
| Token scaduti/usati | Purge > **7 giorni** (`admin token purge`) | Implementato |
| Record nodi | Fino a delete esplicito (hard delete immediato) | Implementato |
| Nodi inattivi | Nessun purge automatico in questa fase (manca l'heartbeat, in arrivo con M-B) | Da fare (M-B) |
| Log del CP | Consigliato 30 giorni, senza contenuti sensibili (i log non contengono mai segreti) | Documentato |

## Recovery — casi pratici

1. **`node.json` perso (secret smarrito)**: `admin node delete <id>` (operatore) → nuovo token → `install.sh --register …`. Non si trasmettono mai segreti dall'operatore all'utente.
2. **Secret sospetto**: l'utente esegue `--rotate-secret` (vecchio invalidato subito).
3. **Token scaduto/riusato**: nuovo token (`admin token create`).
4. **Conflitto 409 su ri-registrazione**: record vecchio ancora presente → delete + nuovo token.

## GDPR (sintesi)

- Dati trattati: **pseudonimi** (pubkey, relay, alias scelto dall'utente, versione, timestamp) — nessuna PII necessaria al servizio.
- Diritto alla cancellazione: self-service (DELETE) o richiesta all'operatore; il delete è immediato e definitivo.
- Minimizzazione: il control plane è opt-in e non è necessario al funzionamento del wallet o del nodo (il nodo vive senza CP).
