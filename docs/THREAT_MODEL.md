# Threat Model — installer + control plane

Scope: `installer/` (runs on the user's server) and `server/` (runs on the
project's infrastructure). Out of scope: the wallet (other repo) and the
CLN/bitcoind node itself.

## Assets

| Asset | Where | Sensitivity |
|---|---|---|
| Registration token | Issued by the CP, used by the installer | Single-use, TTL |
| `node_secret` | `~/.tlw-node/node.json` (user) / hash in the CP | user→CP credential |
| CLN rune | `~/.lightning/bridge-rune` (600) | Restricted control of the node |
| Bridge private key | `~/bridge/config.json` (600) | NWC identity of the bridge |
| NWC/NCC URI | `~/bridge/uri.txt` (600), app | Contains the client secret |
| CLN/bridge binaries | Pinned downloads | Supply chain |

## Threats and mitigations

| # | Threat | Implemented mitigation | Residual limit |
|---|---|---|---|
| 1 | MITM/binary replacement | Pinned version + **hardcoded fail-closed sha256**, HTTPS only, mismatch = abort | GPG signature not integrated yet (roadmap) |
| 2 | Registration of fake nodes | **Single-use** token (TTL 24h, hash at-rest), per-IP rate-limit | The token is delivered by hand (secure channel is the operator's responsibility) |
| 3 | Token theft/reuse | Single-use, expiry, `410` on reuse; a 409 does **not** consume the token | |
| 4 | Node impersonation (GET/DELETE) | `node_secret` 256-bit, **constant-time** comparison, self-service rotation | ID enumeration mitigated by random IDs (128 bit) |
| 5 | Local attacker on the user server | Files 600, no secrets in logs, no sudo, least-privilege rune | User-level execution: a local root can always read the files |
| 6 | Compromised CP | The CP **cannot** move funds or command nodes: zero credentials toward servers, only hashes and pseudonymous data | Data (pubkey/relay) readable by whoever compromises the CP |
| 7 | CP unreachable (down/offline) | Install **offline-ok**; deferred registration (`--register`); the node lives without the CP | |
| 8 | X-Forwarded-For spoofing | `TRUST_PROXY=0` by default; `1` only behind a proxy that rewrites the header | If misconfigured, per-IP rate-limit is bypassable (low impact: protects against abuse, not against brute-force on 256-bit) |
| 9 | Installer supply chain | `set -euo pipefail`, shellcheck in CI/tests, no `sudo`, strict quoting | |
| 10 | Flood/DoS | Per-IP rate-limit with `Retry-After`, body ≤8KB | In-memory: resets on restart (accepted) |

## Explicit statements (not to be forgotten)

- **No custody**: the CP does not sign, does not move funds, does not operate nodes.
- **Outbound-only**: the CP never contacts users' servers; every action
  on the node (URI revocation, stop, uninstall) is **local** via the installer.
- **Minimal data**: pubkey/relay/alias/version/timestamp + hashes. Never seeds,
  runes, RPC credentials or PII.
- **Feature bit 68 / SIGHASH_UNIFIED**: experimental, **never implemented here**
  (only mentioned). No support until the format stabilizes.

## Security roadmap

1. **GPG** verification of upstream `SHA256SUMS` integrated into the installer (pinned upstream key).
2. **Release signing** of the bridge (`btc-blake2b-control-plane`) and GPG verification in deploy.
3. **BIP340 challenge-response** authentication (node pubkey) as an alternative to `node_secret` — the `bridgePubkey` field is already stored for this.
4. Documented log retention for the CP deploy (recommended: 30 days, without contents).
