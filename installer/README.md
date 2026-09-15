# TLW Node Installer — blake2b Lightning node + NWC/NCC bridge

Installs on **your** server a Core Lightning node (**blake2b** fork) and the
NWC/NCC bridge, to control it from the app. No `sudo`: everything user-level
(`~/cln-blake2b`, `~/bridge`, `~/.lightning`).

## Requirements

- Ubuntu **22.04 / 24.04 / 26.04** (x86_64)
- `bitcoind blake2b` reachable via RPC (the full node is **not** included)
- `curl` and `python3` (already present in standard Ubuntu)

## Quick start

```bash
# 1) verify the package checksum (SHA256SUMS in the release)
# 2) extract
tar -xzf tlw-node-installer-{{VERSION}}.tar.gz
cd tlw-node-installer-{{VERSION}}

# 3) dry-run (prints the plan, executes nothing)
./install.sh --dry-run --bitcoind-rpc rpcuser:rpcpass@127.0.0.1:8332

# 4) installation
./install.sh --bitcoind-rpc rpcuser:rpcpass@127.0.0.1:8332
```

At the end the installer prints the **NWC/NCC URI** (and the QR if you have
`qrencode`): paste it into the app (Lightning → Connect). The URI contains a
secret: do not share it.

Registration with the control plane is **optional**: with a token
(`--register-token`) the node is registered at the end; otherwise the
installation still completes and can register later
(`./install.sh --register --register-token … --control-plane …`).

## What gets downloaded (every download is sha256-verified, fail-closed)

| Component | Source |
|---|---|
| Core Lightning blake2b fork `v26.06.7-blake2b.3` | upstream binaries (pin) |
| `bridge-exe-linux-amd64` | release `v0.2.1` of this project (pin) |
| `libpq5` | apt repository (user-level extraction via `apt-get download`) |

A mismatched checksum **aborts** the installation.

## Useful commands

```bash
./install.sh --status                    # node + bridge status
./install.sh --gen-uri                   # authorize a NEW phone (new URI)
./install.sh --revoke-client <pubkey>    # revoke a client from the allowlist
./install.sh --uninstall --yes           # remove binaries/config (datadir UNTOUCHED)
```

In co-tenant setups (several nodes on one machine): `--clnrest-port N`,
`--cln-p2p-port N`, `--cln-grpc-port N`, `--no-systemd`.

## Full guide

In the repository: `docs/INSTALLER.md` (commands, security, FAQ, troubleshooting).
