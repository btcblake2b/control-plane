# Installer guide — blake2b Lightning node + NWC/NCC bridge

`installer/install.sh` installs on **your** server a Core Lightning node
(blake2b fork) and the NWC/NCC bridge, then (optionally) registers the node
with the control plane. **Assisted self-hosted** model: the script runs on
your machine, the control plane never accesses it.

## Download and verification (end user)

1. From the **Releases** page of `btcblake2b/control-plane` download:
   - `tlw-node-installer-0.3.0.tar.gz` — the installation package
   - `SHA256SUMS` — the checksums (package + bridge)
2. Verify the package:

   ```bash
   sha256sum -c SHA256SUMS --ignore-missing
   ```

3. Extract and run:

   ```bash
   tar -xzf tlw-node-installer-0.3.0.tar.gz
   cd tlw-node-installer-0.3.0
   ./install.sh --bitcoind-rpc rpcuser:rpcpass@127.0.0.1:8332
   ```

The installer downloads CLN and the bridge by itself (`bridge-exe-linux-amd64`
asset of the same release) **verifying the pinned sha256**: no manual
downloads required.

## Prerequisites

| Requirement | Notes |
|---|---|
| Ubuntu **22.04 / 24.04 / 26.04**, x86_64 | Other distros: only with custom artifacts (`--cln-url/--cln-sha256 --allow-custom-urls`). Debian 12 is not covered by the upstream binaries. |
| Reachable **bitcoind blake2b** (RPC) | The installer does NOT install the full node (out of scope). Reference: `DarkWebDivingClub/bitcoin-knots`. Auto-detected from `~/.bitcoin/bitcoin.conf` or `--bitcoind-rpc user:pass@host:port`. |
| `curl`, `python3` | Already present in standard Ubuntu. |
| No `sudo` required | Fully user-level installation (`~/cln-blake2b`, `~/bridge`, `~/.lightning`). |

## Quick start

1. Ask the control plane operator for a **registration token** (64 hex, single-use, expires in 24h).
2. On your server:

```bash
./install.sh \
  --bitcoind-rpc rpcuser:rpcpass@127.0.0.1:8332 \
  --control-plane https://cp.example.org \
  --register-token <TOKEN_64_HEX>
```

3. At the end the script prints the **NWC/NCC URI + QR**: paste/scan it in the app
   (Lightning → Connect). The URI contains a secret: do not share it.

If the control plane is unreachable, the installation **still completes**;
registration is deferred:

```bash
./install.sh --register --register-token <TOKEN> --control-plane https://cp.example.org
```

## Commands

| Command | Effect |
|---|---|
| `install.sh [options]` | Install/update (idempotent: never overwrites existing config and rune) |
| `--dry-run` | Prints the full plan without executing anything |
| `--status` | Local status (CLN, bridge, registration) + check with the control plane |
| `--revoke-client <pubkey>` | Removes a client from the bridge allowlist (**local** revocation) |
| `--rotate-secret` | New `node_secret` toward the control plane (the old one is invalidated) |
| `--register` | Deferred registration (uses local state) |
| `--gen-uri` | Authorizes a **new** client and prints the URI (to add a phone) |
| `--uninstall --yes` | Removes binaries and configuration. **The datadir is NOT touched** |
| `--uninstall --yes --purge-datadir` | ALSO removes `~/.lightning` (requires typing `PURGE`; **irreversible**: channels and funds) |

Useful options: `--relay wss://…`, `--alias name`, `--cln-home/--lightning-dir/--bridge-dir/--state-dir`,
`--clnrest-port N` / `--cln-p2p-port N` / `--cln-grpc-port N` (avoid conflicts in co-tenant setups; the
clnrest port is also used by the **bridge config**, so it always talks to YOUR node),
`--no-systemd` (direct start + run.sh).

## What the installer does (steps)

1. Preflight (OS/arch, commands). 2. bitcoind check (TCP). 3. CLN download
`v26.06.7-blake2b.4` with **pinned sha256** → `~/cln-blake2b` (extraction
**complete**: binaries in `usr/bin` + plugins in `usr/libexec` — without the
plugins the node does not start correctly). 4. libpq5 user-level
(`apt-get download` + `dpkg -x`). 5. CLN config (600) + start
(systemd --user or `lightningd --daemon`). 6. Verification `getinfo`. 7. Dedicated
rune (600). 8. Bridge download (sha256) + config (600) + `--genkey`/`--genuri`.
9. `run.sh` with pidfile + systemd unit. 10. Registration (if requested) →
`~/.tlw-node/node.json` (600). 11. Summary with URI + QR.

## Security (by design)

- Every download is **fail-closed**: sha256 mandatory, mismatch = abort.
- Sensitive files always `600` (config, rune, `node.json`, `uri.txt`).
- Logs never contain tokens, runes, keys or secrets (only `~/tlw-node-install.log`).
- Funds-friendly uninstall: the datadir is sacred by default.

## Known limits and notices

- **The URI is reused**: re-running the installer does not regenerate the URI nor
  create ghost clients (for a new phone use `--gen-uri`; to revoke use `--revoke-client <pubkey>`).
- **Bridge release pin is active**: the installer downloads the bridge from this
  project's GitHub Release and verifies the pinned sha256 (fail-closed). Custom
  artifacts (`--bridge-url/--bridge-sha256 --allow-custom-urls`) remain for tests/CI only.
- `--skip-start` is **only for tests/CI** (does not start services).
- **Node upgrade between fork releases** (e.g. `.2`/`.3` → `.4`) is a **separate
  procedure**: close your channels **first** (`.4` enforces bit 68 in `init`: a
  cooperative close with a peer still on `.2`/`.3` is no longer possible), then
  backup of `lightningd.sqlite3`, `hsm_secret`, `emergency.recover`, then first
  start with `--database-upgrade=true` (**one-way**).
- **Feature bit 68 / SIGHASH_UNIFIED**: the `.4` release the installer pins
  signals `option_blake2b` (bit 68) as **mandatory** in `init` and adds unified
  signatures. The bits are **not yet registered BOLT allocations** and may move:
  channels opened under the current numbering may need closing/reopening. The
  remote signer contract (Phase 2) still awaits format stabilization
  (see `SIGNER-CONTRACT.md`).
- Synology/QNAP NAS: not officially supported (community checklist); use only at your own risk.

## FAQ

- **Expired/used token** → ask the operator for a new token (`admin token create`).
- **"node already registered" (409)** → the operator must run `admin node delete <id>` (recovery), then retry with a new token.
- **I lost `node.json`** → recovery as above: delete + new token + `--register`.
- **How do I revoke a phone?** → `--revoke-client <pubkey>` (the pubkey is shown by `--genuri`).
- **The app says "the node has not authorized this app (grant)"** → the bridge is
  responding `RESTRICTED`. Check `clnUrl` in `~/bridge/config.json`: it must point to the
  clnrest port of YOUR node (set by `--clnrest-port`, default 3001; in co-tenant setups with
  several nodes it is the first thing to verify). A revoked client needs a new URI (`--gen-uri`).
