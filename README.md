# btc-blake2b-control-plane

> **Self-hosted, opt-in** support infrastructure for Lightning nodes on **bitcoin-blake2b**:
> a **control plane** (outbound provisioning registry) and an **assisted installer**
> to set up Core Lightning (blake2b fork) + NWC/NCC bridge on your own server.
> It is NOT a wallet and NOT a custody service: keys always stay with the user.

**Phase 1 status**: A1–A5 ✓ completed. **Release `v0.3.0`** of the installation package published (installer + bridge, assets verifiable via `SHA256SUMS`).

## Architecture

```
[Flutter wallet app] ── NWC/NCC (Nostr) ──▶ [Bridge] ── clnrest ──▶ [CLN blake2b fork]   (user's server)
                                                ▲
[user's server] ── registration (single-use token, HTTPS) ──▶ [Control plane]           (registry)
```

- The installer runs **on the user's server**; the control plane **never has access** to servers.
- The CP stores only **pseudonymous** data (bridge pubkey, relay, alias, version, timestamp):
  never seeds, never runes, never access credentials.
- Revoking an NWC URI is **local** (bridge allowlist, via installer), not remote.
- Full trust model: `docs/THREAT_MODEL.md` (A4) · ADRs: `DECISIONS.md` in the wallet repo.

## Non-goals (out of scope, not to be forgotten)

- **No custody**: the CP does not sign, does not move funds, does not operate nodes.
- **Feature bits / unified sighash are upstream, not here**: the installer pins the upstream
  `v26.06.7-blake2b.4` build, which signals `option_blake2b` (bit 68) as **mandatory** in `init`
  and adds SIGHASH_UNIFIED. This repo (control plane, installer, bridge) **never implements
  signing or the bits themselves** — the remote signer contract (Phase 2) awaits stabilization.
- **Live node upgrade to `.4`**: **out of scope** (separate procedure: close channels first —
  bit 68 breaks cooperative close with older peers — then backup of
  `lightningd.sqlite3`/`hsm_secret`/`emergency.recover` + `--database-upgrade=true`, one-way).
- **Remote signer**: it is **Phase 2** (feasibility study, in the wallet's shared memory).
  It will have to handle SIGHASH_UNIFIED, but the final contract waits for the **format to stabilize**.

## Release

- **Installer**: `tlw-node-installer-0.3.0.tar.gz` — from the GitHub Release `v0.3.0` (with `SHA256SUMS`); guide: `docs/INSTALLER.md`.
- **Bridge**: `bridge-exe-linux-amd64` (same release) — built from the source in `bridge/` with `scripts/build-bridge-release.sh` (Dart 3.13.3; source included and rebuildable).
- Packaging: `scripts/package-installer.sh` · publishing: `scripts/publish-release.ps1`.

## Structure

- `server/` — control plane (Dart: `shelf` + SQLite; admin CLI)
- `installer/` — bash installer + Docker tests (Ubuntu matrix; Debian documented)
- `bridge/` — NWC/NCC bridge source (release snapshot; primary development in the wallet repo)
- `scripts/` — bridge build, installer packaging, release publishing
- `docs/` — `INSTALLER.md` · `CONTROL_PLANE.md` · `THREAT_MODEL.md` · `REVOCATION.md` · `SIGNER-CONTRACT.md`
- `.github/` — conventions + `@loop-engineer` agent + `loop-engineering` skill

## References

- Wallet (NWC/NCC client + bridge): `btc-blake2b-wallet` repo
- Project shared memory: `btc-blake2b-wallet/docs/ai-memory/` (`DECISIONS.md`, `domain/lightning-network.md`)
- CLN fork: `privkeyio/lightning` — installer pin `v26.06.7-blake2b.4` (mandatory bit-68
  peering gate; wire protocol provisional). `.3` (db 284) is the previous no-unified-sigs
  release; `.2` superseded/do-not-use.
- blake2b full node: `DarkWebDivingClub/bitcoin-knots`
