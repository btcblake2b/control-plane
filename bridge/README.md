# NWC/NCC ↔ CLN Bridge

Servizio Dart che espone un nodo **Core Lightning** (fork blake2b) via
**Nostr Wallet Connect (NIP-47)** e **NCC** — così l'app Flutter del progetto
(client NWC/NCC già implementato) può gestire pagamenti e canali del nodo
senza modifiche al nodo stesso.

```
App (Flutter) ── NWC/NCC su Nostr ──▶ Bridge ── CLNRest ──▶ nodo CLN
      ▲                                   │
      └──────── risposta cifrata ─────────┘
```

## Requisiti

- Nodo CLN con **clnrest** attivo + una **rune** dedicata
  (sul server attuale: `clnrest-port=3001`, loopback)
- Dart SDK 3.3+
- Un relay Nostr raggiungibile (es. `wss://relay.damus.io`)

## Setup

```bash
cd bridge
dart pub get

# 1) chiave Nostr del bridge
dart run bin/bridge.dart --genkey           # → privkeyHex per config.json

# 2) config
cp config.example.json config.json          # poi compila i campi

# 3) rune dedicata sul nodo (una volta)
lightning-cli createrune                    # → salva in ~/.lightning/bridge-rune
                                            #   formato: LIGHTNING_RUNE="<rune>"

# 4) URI per l'app (registra l'allowlist del client)
dart run bin/bridge.dart --genuri           # → incolla la URI nell'app

# 5) avvio
dart run bin/bridge.dart
```

### Avvio persistente sul server (esempio)

```bash
cd ~/bridge && nohup dart run bin/bridge.dart > bridge.log 2>&1 &
```

## Metodi supportati

| Metodo | Tipo | Comando CLN | Note |
|---|---|---|---|
| `get_info` | NWC | `getinfo` | `network: "blake2b"` |
| `get_balance` | NWC | `listfunds` + `listpeerchannels` | saldo canali attivi + on-chain |
| `make_invoice` | NWC | `invoice` | amount in **msat** |
| `pay_invoice` | NWC | `pay` | ritorna preimage + fee |
| `list_channels` | NCC | `listpeerchannels` | mapping → `LdkChannelInfo` (**msat**) |
| `open_channel` | NCC | `connect` + `fundchannel` | `host` opzionale |
| `close_channel` | NCC | `close` | `force` → chiusura unilaterale |

## Sicurezza

- **Allowlist**: solo le pubkey in `allowedClientPubkeys` possono inviare
  richieste; senza allowlist il bridge non accetta nulla (fail-safe).
  Ogni `--genuri` registra automaticamente la nuova client pubkey.
- **Rune dedicata** (solo `clnrest` loopback): il bridge non ha accesso al
  nodo oltre a ciò che la rune concede — usare una rune separata da quella RTL.
- Il bridge **non logga mai** plaintext, content di eventi, rune o chiavi.
- La secret nella URI è la chiave privata **del client**: conservarla come un
  segreto (va nell'app, non nel repo).

## Limitazioni MVP

- Un solo relay (il primo della config).
- Nessuna notifica push (kind 23196/23200): l'app fa refresh periodico.
- `pay_invoice`/`open_channel` sono sincroni: se il nodo impiega più del
  timeout del client (30 s) la risposta arriva tardi e il client va in timeout.
- Saldi in **msat** (convenzione NWC/LDK).
