# Signer Contract (bozza di dominio — nessuna implementazione)

> **Status: documento informativo.** Questo contratto NON è implementato in
> questa fase. In CLN self-hosted la firma è interna all'`hsmd` (non esposta
> via API): qui si fissa solo il *linguaggio* con cui, in Fase 2, si valuterà
> un signer remoto (pattern Greenlight). Il contratto definitivo **attende la
> stabilizzazione del formato** (vedi "Requisiti blake2b"). Decisione: ADR
> "Lightning signer: strategia a fasi" in `btc-blake2b-wallet/docs/ai-memory/DECISIONS.md`.

## Perimetro

- **Non** è un manuale di implementazione. **Non** modifica CLN, `hsmd` o l'app.
- Serve a: (a) fissare i termini del dominio; (b) rendere comparabili le
  opzioni della feasibility study (fork VLS, signer proprietario, dln-node);
  (c) evitare astrazioni premature nel codice.

## Ruoli

| Ruolo | Chi | Oggi |
|---|---|---|
| Nodo | CLN fork blake2b | Firma localmente (`hsmd`) |
| Firma | `hsmd` interno | Non esposto |
| Contratto remoto (futuro) | Signer sul device (Greenlight-style) | Non implementato |

## Metodi (termini di dominio, stile VLS)

Firme che un signer remoto dovrà eventualmente fornire — semantica, non API:

- `sign_funding_tx` — firma della tx di funding del canale.
- `sign_commitment_tx` — firma della commitment (per-commitment point).
- `sign_htlc_tx` — firma di tx HTLC (offered/received).
- `sign_mutual_close` — firma della chiusura cooperativa.
- `sign_penalty_tx` — firma della justice transaction.
- `sign_delayed_sweep` — firma dello sweep dopo `to_self_delay`.
- `get_per_commitment_point` — derivazione dei per-commitment point.
- `validate_holder_commitment` — validazione di una commitment ricevuta.

Per ciascuno, un eventuale protocollo dovrà definire: input, output, stato
(counter/finestre di ripetizione), gestione errori e **anti-replay**.

## Requisiti blake2b (il punto che rende il contratto "non finale")

- **SIGHASH_UNIFIED** (digest unificato + flag `0x20` per replay protection)
  è **sperimentale e NON presente nel `.3` ufficiale** (`privkeyio/lightning`).
  Un signer remoto dovrà gestirlo, ma il contratto definitivo attende la
  **stabilizzazione del formato** (numeri di feature bit provvisori: 68/71/70).
- Curve e formato transazioni sono identici a Bitcoin mainnet; ciò che cambia
  è la **derivazione del digest da firmare** e l'isolamento dei peer (bit 68).
- Conseguenza: nessuna scelta di schema (serializzazione, MAC, storage)
  è congelata finché il formato non è stabile.

## Non-obiettivi

- Nessuna astrazione `Signer` con implementazioni segnaposto nel codice.
- Nessuna modifica a CLN/`hsmd` né al bridge in questa fase.
- Nessun supporto ai feature bit sperimentali in installer/control plane.

## Criteri di uscita (per la Fase 2)

Il contratto diventa "finale" quando: (1) SIGHASH_UNIFIED è in una release
ufficiale e stabile; (2) esiste una scelta motivata tra le opzioni (fork VLS /
signer proprietario / dln-node); (3) c'è un piano di test su regtest + mainnet
con importi micro e procedure di recovery.
