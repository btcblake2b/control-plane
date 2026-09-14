# Threat Model — installer + control plane

Scope: `installer/` (gira sul server dell'utente) e `server/` (gira
sull'infrastruttura del progetto). Fuori scope: il wallet (altro repo) e il
nodo CLN/bitcoind di per sé.

## Asset

| Asset | Dove | Sensibilità |
|---|---|---|
| Token di registrazione | Emesso dal CP, usato dall'installer | Monouso, TTL |
| `node_secret` | `~/.tlw-node/node.json` (utente) / hash nel CP | Credenziale utente→CP |
| Rune CLN | `~/.lightning/bridge-rune` (600) | Controllo ristretto del nodo |
| Chiave privata bridge | `~/bridge/config.json` (600) | Identità NWC del bridge |
| URI NWC/NCC | `~/bridge/uri.txt` (600), app | Contiene il segreto client |
| Binari CLN/bridge | Download pinned | Supply chain |

## Minacce e mitigazioni

| # | Minaccia | Mitigazione implementata | Limite residuo |
|---|---|---|---|
| 1 | MITM/sostituzione dei binari | Pin versione + **sha256 hardcoded fail-closed**, solo HTTPS, mismatch = abort | Firma GPG non ancora integrata (roadmap) |
| 2 | Registrazione di nodi falsi | Token **monouso** (TTL 24h, hash at-rest), rate-limit per IP | Il token è consegnato a mano (canale sicuro a carico dell'operatore) |
| 3 | Furto/riuso token | Single-use, scadenza, `410` su riuso; il 409 **non** consuma il token | |
| 4 | Impersonificazione del nodo (GET/DELETE) | `node_secret` 256-bit, confronto **constant-time**, rotazione self-service | Enumerazione ID mitigata da ID casuali (128 bit) |
| 5 | Attaccante locale sul server utente | File 600, niente segreti nei log, niente sudo, rune least-privilege | Esecuzione user-level: un root locale può sempre leggere i file |
| 6 | CP compromesso | Il CP **non può** muovere fondi né comandare nodi: zero credenziali verso i server, solo hash e dati pseudonimi | Dati (pubkey/relay) leggibili da chi compromette il CP |
| 7 | CP irraggiungibile (down/offline) | Install **offline-ok**; registrazione differibile (`--register`); il nodo vive senza CP | |
| 8 | X-Forwarded-For spoofing | `TRUST_PROXY=0` di default; `1` solo dietro proxy che riscrive l'header | Se malconfigurato il rate-limit per IP è aggirabile (impatto basso: protegge da abusi, non da brute-force su 256-bit) |
| 9 | Supply chain installer | `set -euo pipefail`, shellcheck in CI/test, nessun `sudo`, quoting rigoroso | |
| 10 | Flood/DoS | Rate-limit per IP con `Retry-After`, body ≤8KB | In-memory: si azzera al riavvio (accettato) |

## Dichiarazioni esplicite (da non dimenticare)

- **Nessuna custodia**: il CP non firma, non muove fondi, non opera sui nodi.
- **Outbound-only**: il CP non contatta mai i server degli utenti; ogni azione
  sul nodo (revoca URI, stop, uninstall) è **locale** via installer.
- **Dati minimi**: pubkey/relay/alias/versione/timestamp + hash. Mai seed,
  rune, credenziali RPC o PII.
- **Feature bit 68 / SIGHASH_UNIFIED**: sperimentali, **mai implementati qui**
  (solo menzionati). Nessun supporto finché il formato non si stabilizza.

## Roadmap sicurezza

1. Verifica **GPG** dei `SHA256SUMS` upstream integrata nell'installer (chiave upstream pinnata).
2. **Firma delle release** del bridge (`btc-blake2b-control-plane`) e verifica GPG nel deploy.
3. Autenticazione **challenge-response BIP340** (pubkey del nodo) come alternativa al `node_secret` — il campo `bridgePubkey` è già registrato per questo.
4. Retention log documentata per il deploy del CP (consigliato: 30 giorni, senza contenuti).
