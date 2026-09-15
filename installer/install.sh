#!/usr/bin/env bash
# TLW Node Installer — nodo Lightning blake2b (fork CLN) + bridge NWC/NCC.
#
# Modello self-hosted assistito: questo script gira SUL server dell'utente;
# il control plane NON ha mai accesso a questa macchina (provisioning outbound).
# Nessun sudo richiesto (installazione user-level).
#
# Sicurezza: ogni download è verificato con sha256 PINNATO (fail-closed);
# nessun segreto (token, secret, rune, chiavi) viene mai loggato.
set -euo pipefail

INSTALLER_VERSION="0.2.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Pin di default (fail-closed) ────────────────────────────────────────────
CLN_RELEASE_DEFAULT="v26.06.7-blake2b.3"
# PERCHÉ .3 e NON .2: .2 è "superseded/do-not-use" (buildata da v26.06.6,
# db 282; rifiuta i db 284 di v26.06.7). Vedi DECISIONS.md / dominio LN.
CLN_SHA256_UBUNTU_2204="9d70d13eab72fe2b727d9070e5a0551280f8154c612f3bb2806c5d7ac9dcbb89"
CLN_SHA256_UBUNTU_2404="439c9e79a4cfb4ed0560a79c5199b2b5006a1cbca6f800934a4e1bc25c3750c5"
CLN_SHA256_UBUNTU_2604="80f53c3cfa95803257722f61d3f3948b9e816af80e1ee5e4ec33f3724020c0c8"

# Bridge: release ufficiale dal repo btc-blake2b-control-plane (v0.2.1).
# Pin ATTIVO: sha256 verificato fail-closed a ogni installazione. L'override
# esplicito (--bridge-url/--bridge-sha256 + --allow-custom-urls) resta per
# test/CI con artifact locali. Build riproducibile: scripts/build-bridge-release.sh.
BRIDGE_RELEASE="v0.2.1"
BRIDGE_URL_DEFAULT="https://github.com/btcblake2b/control-plane/releases/download/${BRIDGE_RELEASE}/bridge-exe-linux-amd64"
BRIDGE_SHA256_DEFAULT="84659dc8b4668ca9635ffbc43369aef53d794646caa8cb21c7d477560327a25a"

# ── Stato (default; sovrascrivibili dai flag) ───────────────────────────────
MODE="install"
ALLOW_CUSTOM_URLS=0
SKIP_START=0
CLN_RELEASE="$CLN_RELEASE_DEFAULT"
CLN_URL=""
CLN_SHA256=""
BRIDGE_URL="$BRIDGE_URL_DEFAULT"
BRIDGE_SHA256="$BRIDGE_SHA256_DEFAULT"
BRIDGE_CUSTOM=0
REGISTER_TOKEN=""
CONTROL_PLANE_URL=""
BTC_RPC_RAW=""
RELAY="wss://relay.primal.net"
NODE_ALIAS="btcblake2b-node"
CONFIRM_YES=0
PURGE_DATADIR=0
REVOKE_PUBKEY=""
CLNREST_PORT="3001"
CLN_P2P_PORT="9735"
CLN_GRPC_PORT="9736"
NO_SYSTEMD=0
TMP_DIR=""

BTC_RPC_HOST="127.0.0.1"
BTC_RPC_PORT="8332"
BTC_RPC_USER=""
BTC_RPC_PASS=""
BRIDGE_PUBKEY=""

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/cln.sh
source "$SCRIPT_DIR/lib/cln.sh"
# shellcheck source=lib/bridge.sh
source "$SCRIPT_DIR/lib/bridge.sh"
# shellcheck source=lib/register.sh
source "$SCRIPT_DIR/lib/register.sh"

usage() {
  cat <<'EOF'
TLW Node Installer — nodo Lightning blake2b + bridge NWC/NCC (self-hosted assistito).

Uso: install.sh [opzioni]

Modalità (default: install):
  --register               registra il nodo al control plane (usa lo stato locale)
  --gen-uri                autorizza un NUOVO client e stampa la URI (nuovo telefono)
  --status                 stato locale + verifica sul control plane
  --revoke-client PUBKEY   rimuove un client dall'allowlist del bridge (64 hex)
  --rotate-secret          ruota il node_secret verso il control plane
  --uninstall              rimuove binari e configurazioni (richiede --yes)
  --purge-datadir          con --uninstall: rimuove ANCHE il datadir CLN (one-way!)

Opzioni install:
  --bitcoind-rpc U:P@H:P   RPC del bitcoind blake2b (default: ~/.bitcoin/bitcoin.conf)
  --relay WSS              relay Nostr del bridge (default: wss://relay.primal.net)
  --alias NOME             alias del nodo (default: btcblake2b-node)
  --register-token TOKEN   token monouso del control plane (64 hex)
  --control-plane URL      URL del control plane (es. https://cp.example.org)
  --skip-start             NON avvia i servizi (solo test/CI)
  --clnrest-port N         porta REST di CLN (default: 3001; utile in co-tenant)
  --cln-p2p-port N         porta P2P di CLN (default: 9735; utile in co-tenant)
  --cln-grpc-port N        porta gRPC di CLN (default: 9736; utile in co-tenant)
  --no-systemd             NON usare systemd --user (avvio diretto + run.sh)
  --allow-custom-urls      consenti URL/sha256 custom (test/CI)
  --cln-url URL            override URL binari CLN (richiede --cln-sha256)
  --cln-sha256 SHA         checksum atteso dei binari CLN (fail-closed)
  --cln-release TAG        tag release CLN custom (richiede --cln-sha256)
  --bridge-url URL         override URL binario bridge (richiede --bridge-sha256)
  --bridge-sha256 SHA      checksum atteso del bridge (fail-closed)
  --cln-home DIR           default: ~/cln-blake2b
  --lightning-dir DIR      default: ~/.lightning
  --bridge-dir DIR         default: ~/bridge
  --state-dir DIR          default: ~/.tlw-node
  --dry-run                stampa il piano senza eseguire nulla
  -h, --help               mostra questo aiuto
EOF
}

set_mode() {
  if [[ "$MODE" != "install" ]]; then
    die "specifica una sola modalità (già impostata: $MODE)"
  fi
  MODE="$1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --allow-custom-urls) ALLOW_CUSTOM_URLS=1 ;;
      --skip-start) SKIP_START=1 ;;
      --clnrest-port) CLNREST_PORT="${2:?manca il valore per --clnrest-port}"; shift ;;
      --cln-p2p-port) CLN_P2P_PORT="${2:?manca il valore per --cln-p2p-port}"; shift ;;
      --cln-grpc-port) CLN_GRPC_PORT="${2:?manca il valore per --cln-grpc-port}"; shift ;;
      --no-systemd) NO_SYSTEMD=1 ;;
      --cln-url) CLN_URL="${2:?manca il valore per --cln-url}"; shift ;;
      --cln-sha256) CLN_SHA256="${2:?manca il valore per --cln-sha256}"; shift ;;
      --cln-release) CLN_RELEASE="${2:?manca il valore per --cln-release}"; shift ;;
      --bridge-url) BRIDGE_URL="${2:?manca il valore per --bridge-url}"; BRIDGE_CUSTOM=1; shift ;;
      --bridge-sha256) BRIDGE_SHA256="${2:?manca il valore per --bridge-sha256}"; BRIDGE_CUSTOM=1; shift ;;
      --bitcoind-rpc) BTC_RPC_RAW="${2:?manca il valore per --bitcoind-rpc}"; shift ;;
      --relay) RELAY="${2:?manca il valore per --relay}"; shift ;;
      --alias) NODE_ALIAS="${2:?manca il valore per --alias}"; shift ;;
      --register-token) REGISTER_TOKEN="${2:?manca il valore per --register-token}"; shift ;;
      --control-plane) CONTROL_PLANE_URL="${2:?manca il valore per --control-plane}"; shift ;;
      --register) set_mode register ;;
      --gen-uri) set_mode genuri ;;
      --status) set_mode status ;;
      --revoke-client) set_mode revoke; REVOKE_PUBKEY="${2:?manca la pubkey}"; shift ;;
      --rotate-secret) set_mode rotate ;;
      --uninstall) set_mode uninstall ;;
      --yes|-y) CONFIRM_YES=1 ;;
      --purge-datadir) PURGE_DATADIR=1 ;;
      --cln-home) CLN_HOME="${2:?manca il valore per --cln-home}"; shift ;;
      --lightning-dir) LIGHTNING_DIR="${2:?manca il valore per --lightning-dir}"; shift ;;
      --bridge-dir) BRIDGE_DIR="${2:?manca il valore per --bridge-dir}"; shift ;;
      --state-dir) NODE_STATE_DIR="${2:?manca il valore per --state-dir}"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "argomento non riconosciuto: $1 (usa --help)" ;;
    esac
    shift
  done
}

ubuntu_version_or_die() {
  [[ -f /etc/os-release ]] || die "/etc/os-release assente: distro non riconosciuta"
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "${VERSION_ID:?VERSION_ID assente in /etc/os-release}"
}

validate_args() {
  if [[ "$MODE" != "install" ]]; then
    return 0
  fi
  need_cmd curl
  need_cmd sha256sum
  need_cmd awk
  need_cmd sed
  need_cmd python3
  need_cmd tar

  # CLN: pin di default oppure override esplicito (sempre con checksum).
  if [[ -n "$CLN_URL" || "$CLN_RELEASE" != "$CLN_RELEASE_DEFAULT" ]]; then
    [[ "$ALLOW_CUSTOM_URLS" == "1" ]] \
      || die "--cln-url/--cln-release richiedono --allow-custom-urls (artifact non ufficiali)"
    [[ -n "$CLN_SHA256" ]] || die "override CLN richiede --cln-sha256 (fail-closed)"
    if [[ -z "$CLN_URL" ]]; then
      CLN_URL="https://github.com/privkeyio/lightning/releases/download/${CLN_RELEASE}/clightning-${CLN_RELEASE}-Ubuntu-$(ubuntu_version_or_die)-amd64.tar.xz"
    fi
  else
    [[ -z "$CLN_SHA256" ]] || die "--cln-sha256 richiede --cln-url (o --cln-release)"
    resolve_cln_pin
  fi

  # Bridge: default = release ufficiale (non ancora pubblicata) → fail-closed.
  if [[ "$BRIDGE_CUSTOM" == "1" ]]; then
    [[ "$ALLOW_CUSTOM_URLS" == "1" ]] \
      || die "--bridge-url/--bridge-sha256 richiedono --allow-custom-urls (artifact non ufficiali)"
    [[ -n "$BRIDGE_SHA256" ]] || die "override bridge richiede --bridge-sha256 (fail-closed)"
  elif [[ -z "$BRIDGE_SHA256" ]]; then
    die "release del bridge non ancora pubblicata ($BRIDGE_URL_DEFAULT): usa --bridge-url/--bridge-sha256 con --allow-custom-urls (test/CI) oppure attendi la release ufficiale"
  fi

  case "$RELAY" in
    wss://* | ws://*) : ;;
    *) die "--relay deve iniziare con wss:// (ricevuto: $RELAY)" ;;
  esac

  if [[ -n "$REGISTER_TOKEN" ]]; then
    require_hex64 "$REGISTER_TOKEN" "token di registrazione"
    [[ -n "$CONTROL_PLANE_URL" ]] || die "--register-token richiede --control-plane URL"
  fi
}

detect_bitcoind() {
  if [[ -n "$BTC_RPC_RAW" ]]; then
    # PERCHÉ (.+): la password può contenere caratteri speciali (es. '@'):
    # si divide sull'ULTIMA '@' prima di host:port, non sulla prima.
    [[ "$BTC_RPC_RAW" =~ ^([^:]+):(.+)@([^:]+):([0-9]+)$ ]] \
      || die "--bitcoind-rpc non valido (atteso user:pass@host:port)"
    BTC_RPC_USER="${BASH_REMATCH[1]}"
    BTC_RPC_PASS="${BASH_REMATCH[2]}"
    BTC_RPC_HOST="${BASH_REMATCH[3]}"
    BTC_RPC_PORT="${BASH_REMATCH[4]}"
  else
    local conf="$HOME/.bitcoin/bitcoin.conf"
    [[ -f "$conf" ]] || die "bitcoind non rilevato: passa --bitcoind-rpc user:pass@host:port (o crea $conf)"
    BTC_RPC_USER="$(sed -n 's/^rpcuser=//p' "$conf" | head -n 1)"
    BTC_RPC_PASS="$(sed -n 's/^rpcpassword=//p' "$conf" | head -n 1)"
    local port host
    port="$(sed -n 's/^rpcport=//p' "$conf" | head -n 1)"
    host="$(sed -n 's/^rpcconnect=//p' "$conf" | head -n 1)"
    BTC_RPC_PORT="${port:-8332}"
    BTC_RPC_HOST="${host:-127.0.0.1}"
    [[ -n "$BTC_RPC_USER" && -n "$BTC_RPC_PASS" ]] \
      || die "rpcuser/rpcpassword mancanti in $conf: passa --bitcoind-rpc"
  fi
  # Verifica TCP senza credenziali applicative (bash /dev/tcp).
  if ! (exec 3<>"/dev/tcp/$BTC_RPC_HOST/$BTC_RPC_PORT") 2>/dev/null; then
    die "bitcoind non raggiungibile su $BTC_RPC_HOST:$BTC_RPC_PORT (il full node blake2b è un prerequisito)"
  fi
  log "bitcoind raggiungibile su $BTC_RPC_HOST:$BTC_RPC_PORT"
  # NB: mai loggare le credenziali RPC.
}

mode_install() {
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  log "TLW Node Installer $INSTALLER_VERSION — inizio installazione"

  check_ubuntu_arch

  if [[ "$SKIP_START" != "1" ]]; then
    detect_bitcoind
  else
    log "verifica bitcoind saltata (--skip-start: solo test/CI)"
  fi

  install_cln_binaries
  install_libpq
  write_cln_config
  start_cln
  wait_cln_ready
  create_rune

  install_bridge_binary
  write_bridge_config
  ensure_bridge_uri
  write_bridge_run_sh
  start_bridge
  check_linger

  if [[ -n "$REGISTER_TOKEN" ]]; then
    register_node
  elif [[ -n "$CONTROL_PLANE_URL" ]]; then
    log "registrazione rimandata: esegui  $0 --register --register-token <TOKEN> --control-plane $CONTROL_PLANE_URL  quando vuoi"
  fi

  print_summary
  log "installazione completata"
}

check_ubuntu_arch() {
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "x86_64" ]]; then
    die "architettura non supportata: $arch (i binari upstream sono amd64/x86_64)"
  fi
}

print_summary() {
  local bindir
  bindir="$(cln_bin_dir)"
  printf '\n================= RIEPILOGO INSTALLAZIONE =================\n'
  printf '  CLN:      %s\n' "$bindir/lightningd"
  printf '  datadir:  %s\n' "$LIGHTNING_DIR"
  printf '  bridge:   %s\n' "$BRIDGE_DIR"
  printf '  log:      %s\n' "$LOG_FILE"
  print_bridge_uri
  printf '\nProssimi passi:\n'
  printf '  1) Incolla/scansiona la URI nell'"'"'app (sezione Lightning → Connetti)\n'
  printf '  2) Deposita fondi on-chain sul nodo, poi apri un canale (anche via app/NCC)\n'
  printf '  3) Comandi utili:\n'
  printf '       %s --status\n' "$0"
  printf '       %s --revoke-client <pubkey>\n' "$0"
  printf '       %s --rotate-secret\n' "$0"
  printf '       %s --uninstall --yes\n' "$0"
}

mode_uninstall() {
  [[ "$CONFIRM_YES" == "1" ]] || die "l'uninstall richiede --yes (il datadir NON viene toccato: fondi e canali al sicuro)"
  log "== uninstall =="
  stop_all_services
  if [[ -d "$BRIDGE_DIR" && "$BRIDGE_DIR" != "/" ]]; then
    rm -rf "$BRIDGE_DIR"
    log "rimosso $BRIDGE_DIR"
  fi
  if [[ -d "$CLN_HOME" && "$CLN_HOME" != "/" ]]; then
    rm -rf "$CLN_HOME"
    log "rimosso $CLN_HOME"
  fi
  if [[ -d "$NODE_STATE_DIR" && "$NODE_STATE_DIR" != "/" ]]; then
    rm -rf "$NODE_STATE_DIR"
    log "rimosso $NODE_STATE_DIR"
  fi
  log "DATADIR INTATTO: $LIGHTNING_DIR (fondi, canali, hsm_secret, rune restano qui)"
  if [[ "$PURGE_DATADIR" == "1" ]]; then
    warn "stai per RIMUOVERE il datadir di CLN: canali e fondi diventeranno IRRECUPERABILI"
    printf 'Digita PURGE (maiuscolo) per confermare: '
    local answer=""
    read -r answer || true
    [[ "$answer" == "PURGE" ]] || die "purge annullato (input non corrispondente)"
    rm -rf "$LIGHTNING_DIR"
    log "datadir RIMOSSO: $LIGHTNING_DIR"
  fi
}

stop_all_services() {
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user disable --now bridge.service >/dev/null 2>&1 || true
    systemctl --user disable --now cln-blake2b.service >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/bridge.service" "$HOME/.config/systemd/user/cln-blake2b.service"
  fi
  if [[ -x "$BRIDGE_DIR/run.sh" ]]; then
    "$BRIDGE_DIR/run.sh" stop >/dev/null 2>&1 || true
  fi
  if [[ -n "$(find "$CLN_HOME" -maxdepth 4 -type f -name lightning-cli -print -quit 2>/dev/null || true)" ]]; then
    cln_cli stop >/dev/null 2>&1 || warn "stop di lightningd non riuscito (già spento?)"
  fi
}

print_plan() {
  local reg="no"
  if [[ -n "$REGISTER_TOKEN" ]]; then
    reg="sì (registrazione al control plane)"
  fi
  cat <<EOF
Piano di installazione (DRY-RUN — nessuna modifica verrà eseguita):
  1. Preflight: OS/arch, comandi richiesti
  2. bitcoind: ${BTC_RPC_RAW:+check RPC custom}${BTC_RPC_RAW:-autodetect ~/.bitcoin/bitcoin.conf}
  3. Download CLN   : $CLN_URL
     checksum       : $CLN_SHA256
  4. Download bridge: $BRIDGE_URL
     checksum       : $BRIDGE_SHA256
  5. Config CLN     : $LIGHTNING_DIR/config (mai sovrascritta se esistente)
  6. Avvio servizi  : systemd --user o fallback run.sh (skip-start=$SKIP_START)
  7. Rune dedicata  : $LIGHTNING_DIR/bridge-rune (mai ricreata se esistente)
  8. Bridge         : config $BRIDGE_DIR/config.json + URI/QR per l'app
  9. Registrazione  : $reg
 10. Riepilogo finale con URI da incollare nell'app
EOF
}

main() {
  parse_args "$@"
  init_log_file
  validate_args
  case "$MODE" in
    install)
      if [[ "$DRY_RUN" == "1" ]]; then
        print_plan
        exit 0
      fi
      mode_install
      ;;
    register) mode_register ;;
    genuri) mode_gen_uri ;;
    status) mode_status ;;
    revoke) mode_revoke_client "$REVOKE_PUBKEY" ;;
    rotate) mode_rotate_secret ;;
    uninstall) mode_uninstall ;;
    *) die "modalità sconosciuta: $MODE" ;;
  esac
}

main "$@"
