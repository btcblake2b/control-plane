# Signer Contract (domain draft — no implementation)

> **Status: informational document.** This contract is NOT implemented in
> this phase. In self-hosted CLN signing is internal to `hsmd` (not exposed
> via API): here we only fix the *language* with which, in Phase 2, a remote
> signer (Greenlight pattern) will be evaluated. The final contract **waits for
> the format to stabilize** (see "blake2b requirements"). Decision: ADR
> "Lightning signer: phased strategy" in `btc-blake2b-wallet/docs/ai-memory/DECISIONS.md`.

## Scope

- It is **not** an implementation manual. It **does not** modify CLN, `hsmd` or the app.
- It serves to: (a) fix the domain terms; (b) make the feasibility-study
  options comparable (VLS fork, proprietary signer, dln-node);
  (c) avoid premature abstractions in the code.

## Roles

| Role | Who | Today |
|---|---|---|
| Node | CLN blake2b fork | Signs locally (`hsmd`) |
| Signing | internal `hsmd` | Not exposed |
| Remote contract (future) | Signer on the device (Greenlight-style) | Not implemented |

## Methods (domain terms, VLS style)

Signatures a remote signer will eventually have to provide — semantics, not API:

- `sign_funding_tx` — channel funding tx signature.
- `sign_commitment_tx` — commitment signature (per-commitment point).
- `sign_htlc_tx` — HTLC tx signature (offered/received).
- `sign_mutual_close` — cooperative close signature.
- `sign_penalty_tx` — justice transaction signature.
- `sign_delayed_sweep` — sweep signature after `to_self_delay`.
- `get_per_commitment_point` — per-commitment point derivation.
- `validate_holder_commitment` — validation of a received commitment.

For each one, a future protocol will have to define: input, output, state
(counter/repetition windows), error handling and **anti-replay**.

## blake2b requirements (what makes the contract "not final")

- **SIGHASH_UNIFIED** (unified digest + `0x20` flag for replay protection)
  is **experimental and NOT present in official `.3`** (`privkeyio/lightning`).
  A remote signer will have to handle it, but the final contract waits for the
  **format to stabilize** (provisional feature bit numbers: 68/71/70).
- Curves and transaction format are identical to Bitcoin mainnet; what changes
  is the **derivation of the digest to sign** and peer isolation (bit 68).
- Consequence: no schema choice (serialization, MAC, storage)
  is frozen until the format is stable.

## Non-goals

- No `Signer` abstraction with placeholder implementations in the code.
- No changes to CLN/`hsmd` or the bridge in this phase.
- No support for the experimental feature bits in installer/control plane.

## Exit criteria (for Phase 2)

The contract becomes "final" when: (1) SIGHASH_UNIFIED is in a stable
official release; (2) there is a motivated choice among the options (VLS fork /
proprietary signer / dln-node); (3) there is a test plan on regtest + mainnet
with micro amounts and recovery procedures.
