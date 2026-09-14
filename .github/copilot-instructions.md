# Istruzioni per agenti AI — btc-blake2b-control-plane

Repo di **infrastruttura** per nodi Lightning su bitcoin-blake2b (control plane + installer).
NON contiene il wallet (repo separato: `btc-blake2b-wallet`).

## Contesto

- L'utente scrive in **italiano**: output in italiano; commenti nel codice in italiano.
- Per task strutturati (feature, fix, refactor, analisi) usa l'agente **@loop-engineer**
  (`.github/agents/loop-engineer.agent.md` + skill `.github/skills/loop-engineering/SKILL.md`).
- La **memoria condivisa** del progetto vive in `btc-blake2b-wallet/docs/ai-memory/`:
  leggi `DECISIONS.md` e `domain/lightning-network.md` prima di decisioni architetturali.
- Le decisioni architetturali nuove si registrano in `btc-blake2b-wallet/docs/ai-memory/DECISIONS.md`.

## Convenzioni tecniche

- **Server (Dart)**: `dart analyze` con 0 issue e `dart test` verdi prima di ogni commit.
  Modelli manuali (`const` constructor, `toMap`/`fromMap`), niente codegen.
- **Installer (bash)**: `set -euo pipefail`, `shellcheck` pulito, mai `sudo`,
  download sempre con **checksum fail-closed** (niente fallback silenziosi).
- **Sicurezza**: MAI segreti/seed/rune/chiavi reali in file, log, esempi, test
  (solo placeholder). Log strutturati senza dati sensibili.
- **Non-obiettivi** (non implementare senza ADR): custodia/firma server-side per conto terzi,
  feature bit 68 / SIGHASH_UNIFIED (sperimentali, solo menzione), upgrade del nodo live `.2`→`.3`.
