# Guida all'installer — nodo Lightning blake2b + bridge NWC/NCC

`installer/install.sh` installa sul **tuo** server un nodo Core Lightning (fork
blake2b) e il bridge NWC/NCC, poi (opzionalmente) registra il nodo al control
plane. Modello **self-hosted assistito**: lo script gira sulla tua macchina, il
control plane non vi accede mai.

## Download e verifica (utente finale)

1. Dalla pagina **Releases** di `btcblake2b/control-plane` scarica:
   - `tlw-node-installer-0.1.0.tar.gz` — il pacchetto di installazione
   - `SHA256SUMS` — i checksum (pacchetto + bridge)
2. Verifica il pacchetto:

   ```bash
   sha256sum -c SHA256SUMS --ignore-missing
   ```

3. Estrai ed esegui:

   ```bash
   tar -xzf tlw-node-installer-0.1.0.tar.gz
   cd tlw-node-installer-0.1.0
   ./install.sh --bitcoind-rpc rpcuser:rpcpass@127.0.0.1:8332
   ```

L'installer scarica da solo CLN e il bridge (asset `bridge-exe-linux-amd64`
della stessa release) **verificando lo sha256 pinnato**: non serve scaricarli
a mano.

## Prerequisiti

| Requisito | Note |
|---|---|
| Ubuntu **22.04 / 24.04 / 26.04**, x86_64 | Altre distro: solo con artifact custom (`--cln-url/--cln-sha256 --allow-custom-urls`). Debian 12 non è coperta dai binari upstream. |
| **bitcoind blake2b** raggiungibile (RPC) | L'installer NON installa il full node (fuori scope). Riferimento: `DarkWebDivingClub/bitcoin-knots`. Auto-detect da `~/.bitcoin/bitcoin.conf` o `--bitcoind-rpc user:pass@host:port`. |
| `curl`, `python3` | Già presenti su Ubuntu standard. |
| Nessun `sudo` richiesto | Installazione completamente user-level (`~/cln-blake2b`, `~/bridge`, `~/.lightning`). |

## Quick start

1. Chiedi all'operatore del control plane un **token di registrazione** (64 hex, monouso, scade in 24h).
2. Sul tuo server:

```bash
./install.sh \
  --bitcoind-rpc rpcuser:rpcpass@127.0.0.1:8332 \
  --control-plane https://cp.example.org \
  --register-token <TOKEN_64_HEX>
```

3. Alla fine lo script stampa **URI NWC/NCC + QR**: incollala/scansionala nell'app
   (sezione Lightning → Connetti). La URI contiene un segreto: non condividerla.

Se il control plane è irraggiungibile, l'installazione **completa comunque**;
la registrazione si differisce:

```bash
./install.sh --register --register-token <TOKEN> --control-plane https://cp.example.org
```

## Comandi

| Comando | Effetto |
|---|---|
| `install.sh [opzioni]` | Installa/aggiorna (idempotente: non sovrascrive config e rune esistenti) |
| `--dry-run` | Stampa il piano completo senza eseguire nulla |
| `--status` | Stato locale (CLN, bridge, registrazione) + verifica sul control plane |
| `--revoke-client <pubkey>` | Rimuove un client dall'allowlist del bridge (revoca **locale**) |
| `--rotate-secret` | Nuovo `node_secret` verso il control plane (il vecchio viene invalidato) |
| `--register` | Registrazione differita (usa lo stato locale) |
| `--gen-uri` | Autorizza un **nuovo** client e stampa la URI (per aggiungere un telefono) |
| `--uninstall --yes` | Rimuove binari e configurazioni. **Il datadir NON viene toccato** |
| `--uninstall --yes --purge-datadir` | Rimuove ANCHE `~/.lightning` (richiede digitare `PURGE`; **irreversibile**: canali e fondi) |

Opzioni utili: `--relay wss://…`, `--alias nome`, `--cln-home/--lightning-dir/--bridge-dir/--state-dir`,
`--clnrest-port N` / `--cln-p2p-port N` / `--cln-grpc-port N` (evitano conflitti in co-tenant; la porta
clnrest viene usata anche dalla **config del bridge**, che quindi parla sempre con il TUO nodo),
`--no-systemd` (avvio diretto + run.sh).

## Cosa fa l'installer (passi)

1. Preflight (OS/arch, comandi). 2. Verifica bitcoind (TCP). 3. Download CLN
`v26.06.7-blake2b.3` con **sha256 pinnato** → `~/cln-blake2b` (estrazione
**completa**: binari in `usr/bin` + plugin in `usr/libexec` — senza i plugin
il nodo non parte correttamente). 4. libpq5
user-level (`apt-get download` + `dpkg -x`). 5. Config CLN (600) + avvio
(systemd --user o `lightningd --daemon`). 6. `getinfo` di verifica. 7. Rune
dedicata (600). 8. Download bridge (sha256) + config (600) + `--genkey`/`--genuri`.
9. `run.sh` con pidfile + unit systemd. 10. Registrazione (se richiesta) →
`~/.tlw-node/node.json` (600). 11. Riepilogo con URI + QR.

## Sicurezza (by design)

- Ogni download è **fail-closed**: sha256 obbligatorio, mismatch = abort.
- File sensibili sempre `600` (config, rune, `node.json`, `uri.txt`).
- Nei log non finiscono mai token, rune, chiavi o secret (solo `~/tlw-node-install.log`).
- Uninstall compatibile coi fondi: il datadir è sacro di default.

## Limiti noti e avvisi

- **La URI viene riusata**: un re-run dell'installazione non rigenera l'URI né crea client
  fantasma (per un nuovo telefono usa `--gen-uri`; per revocare `--revoke-client <pubkey>`).
- **Release del bridge in preparazione**: il pin ufficiale verrà attivato alla
  pubblicazione; fino ad allora l'installer richiede artifact espliciti
  (`--bridge-url/--bridge-sha256 --allow-custom-urls`, uso test/CI).
- `--skip-start` è **solo per test/CI** (non avvia i servizi).
- **Upgrade del nodo da `.2` a `.3`**: è **fuori scope** di questa fase. Se lo
  farai, è una procedura separata: backup di `lightningd.sqlite3`, `hsm_secret`,
  `emergency.recover`, poi primo avvio con `--database-upgrade=true` (**one-way**).
- **Feature bit 68 / SIGHASH_UNIFIED**: sperimentali, NON presenti nel `.3`
  ufficiale. L'installer non li supporta e non li installerà finché il formato
  non sarà stabile (vedi `SIGNER-CONTRACT.md`).
- NAS Synology/QNAP: non supportati ufficialmente (checklist community); usare
  solo se a proprio rischio.

## FAQ

- **Token scaduto/utilizzato** → chiedi un nuovo token all'operatore (`admin token create`).
- **"nodo già registrato" (409)** → l'operatore deve fare `admin node delete <id>` (recovery), poi riprova con un nuovo token.
- **Ho perso `node.json`** → recovery come sopra: delete + nuovo token + `--register`.
- **Come revoco un telefono?** → `--revoke-client <pubkey>` (la pubkey è mostrata da `--genuri`).
- **L'app dice "il nodo non ha autorizzato questa app (grant)"** → è il bridge che risponde
  `RESTRICTED`. Controlla `clnUrl` in `~/bridge/config.json`: deve puntare alla porta clnrest del
  TUO nodo (scritta da `--clnrest-port`, default 3001; in co-tenant con più nodi la prima cosa da
  verificare). Un client revocato richiede una nuova URI (`--gen-uri`).
