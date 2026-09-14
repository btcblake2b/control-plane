# TLW Node Installer — nodo Lightning blake2b + bridge NWC/NCC

Installa sul **tuo** server un nodo Core Lightning (fork **blake2b**) e il
bridge NWC/NCC, per gestirlo dall'app. Nessun `sudo`: tutto user-level
(`~/cln-blake2b`, `~/bridge`, `~/.lightning`).

## Requisiti

- Ubuntu **22.04 / 24.04 / 26.04** (x86_64)
- `bitcoind blake2b` raggiungibile via RPC (il full node **non** è incluso)
- `curl` e `python3` (già presenti su Ubuntu standard)

## Quick start

```bash
# 1) verifica il checksum del pacchetto (SHA256SUMS nella release)
# 2) estrai
tar -xzf tlw-node-installer-{{VERSION}}.tar.gz
cd tlw-node-installer-{{VERSION}}

# 3) dry-run (stampa il piano, non esegue nulla)
./install.sh --dry-run --bitcoind-rpc rpcuser:rpcpass@127.0.0.1:8332

# 4) installazione
./install.sh --bitcoind-rpc rpcuser:rpcpass@127.0.0.1:8332
```

Alla fine l'installer stampa la **URI NWC/NCC** (e il QR se hai `qrencode`):
incollala nell'app (sezione Lightning → Connetti). La URI contiene un
segreto: non condividerla.

La registrazione al control plane è **opzionale**: se hai un token
(`--register-token`) il nodo viene registrato alla fine; altrimenti
l'installazione è comunque completa e potrà registrarsi dopo
(`./install.sh --register --register-token … --control-plane …`).

## Cosa viene scaricato (ogni download è sha256-verificato, fail-closed)

| Componente | Fonte |
|---|---|
| Core Lightning fork blake2b `v26.06.7-blake2b.3` | binari upstream (pin) |
| `bridge-exe-linux-amd64` | release `v0.1.0` di questo progetto (pin) |
| `libpq5` | repository apt (estrazione user-level via `apt-get download`) |

Un checksum non corrispondente **abortisce** l'installazione.

## Comandi utili

```bash
./install.sh --status                    # stato nodo + bridge
./install.sh --gen-uri                   # autorizza un NUOVO telefono (nuova URI)
./install.sh --revoke-client <pubkey>    # revoca un client dall'allowlist
./install.sh --uninstall --yes           # rimuove binari/config (datadir INTATTO)
```

In co-tenant (più nodi sulla stessa macchina): `--clnrest-port N`,
`--cln-p2p-port N`, `--cln-grpc-port N`, `--no-systemd`.

## Guida completa

Nel repository: `docs/INSTALLER.md` (comandi, sicurezza, FAQ, troubleshooting).
