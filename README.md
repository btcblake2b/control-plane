# btc-blake2b-control-plane

> Infrastruttura di supporto **self-hosted opt-in** per nodi Lightning su **bitcoin-blake2b**:
> un **control plane** (registro di provisioning outbound) e un **installer assistito**
> per installare Core Lightning (fork blake2b) + bridge NWC/NCC sul proprio server.
> NON è un wallet e NON è un servizio di custodia: le chiavi restano dell'utente.

**Stato Fase 1**: A1–A5 ✓ completata. **Release `v0.2.0`** del pacchetto di installazione pubblicata (installer + bridge, asset verificabili via `SHA256SUMS`).

## Architettura

```
[App wallet Flutter] ── NWC/NCC (Nostr) ──▶ [Bridge] ── clnrest ──▶ [CLN fork blake2b]   (server dell'utente)
                                                 ▲
[server dell'utente] ── registrazione (token monouso, HTTPS) ──▶ [Control plane]         (registro)
```

- L'installer gira **sul server dell'utente**; il control plane **non ha mai accesso** ai server.
- Il CP conserva solo dati **pseudonimi** (pubkey bridge, relay, alias, versione, timestamp):
  mai seed, mai rune, mai credenziali di accesso.
- La revoca di un URI NWC è **locale** (allowlist del bridge, via installer), non remota.
- Modello di fiducia completo: `docs/THREAT_MODEL.md` (A4) · ADR: `DECISIONS.md` nel repo wallet.

## Non-obiettivi (fuori scope, da non dimenticare)

- **Nessuna custodia**: il CP non firma, non muove fondi, non opera sui nodi.
- **Feature bit sperimentali**: il bit 68 (required) e SIGHASH_UNIFIED delle build community
  sono **sperimentali e NON presenti nel `.3` ufficiale** (`privkeyio/lightning`).
  Qui sono **solo menzionati, mai implementati**.
- **Upgrade del nodo live `.2` → `.3`**: **fuori scope** di questa Fase 1 (decisione separata:
  backup di `lightningd.sqlite3`/`hsm_secret`/`emergency.recover` + `--database-upgrade=true`, one-way).
- **Signer remoto**: è la **Fase 2** (feasibility study, nella memoria condivisa del wallet).
  Dovrà gestire SIGHASH_UNIFIED, ma il contratto definitivo attende la **stabilizzazione del formato**.

## Release

- **Installer**: `tlw-node-installer-0.2.0.tar.gz` — dalla GitHub Release `v0.2.0` (con `SHA256SUMS`); guida: `docs/INSTALLER.md`.
- **Bridge**: `bridge-exe-linux-amd64` (stessa release) — buildato dal sorgente in `bridge/` con `scripts/build-bridge-release.sh` (Dart 3.13.3; sorgente incluso e ricostruibile).
- Packaging: `scripts/package-installer.sh` · pubblicazione: `scripts/publish-release.ps1`.

## Struttura

- `server/` — control plane (Dart: `shelf` + SQLite; admin CLI)
- `installer/` — installer bash + test Docker (matrice Ubuntu; Debian documentato)
- `bridge/` — sorgente del bridge NWC/NCC (snapshot di release; sviluppo primario nel repo wallet)
- `scripts/` — build bridge, packaging installer, pubblicazione release
- `docs/` — `INSTALLER.md` · `CONTROL_PLANE.md` · `THREAT_MODEL.md` · `REVOCATION.md` · `SIGNER-CONTRACT.md`
- `.github/` — convenzioni + agente `@loop-engineer` + skill `loop-engineering`

## Riferimenti

- Wallet (client NWC/NCC + bridge): repo `btc-blake2b-wallet`
- Memoria condivisa del progetto: `btc-blake2b-wallet/docs/ai-memory/` (`DECISIONS.md`, `domain/lightning-network.md`)
- Fork CLN: `privkeyio/lightning` — release corrente `v26.06.7-blake2b.3` (db 284; `.2` superseded/do-not-use)
- Full node blake2b: `DarkWebDivingClub/bitcoin-knots`
