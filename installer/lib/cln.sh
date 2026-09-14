#!/usr/bin/env bash
# Setup di Core Lightning (fork blake2b) — user-level, senza sudo.

# Rileva la versione Ubuntu e mappa il pin ufficiale (URL + sha256).
# Esporta: VERSION_ID, CLN_URL, CLN_SHA256
resolve_cln_pin() {
  [[ -f /etc/os-release ]] || die "/etc/os-release assente: distro non riconosciuta"
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "distro '${ID:-sconosciuta}' non supportata dai binari upstream: usa --cln-url/--cln-sha256 con --allow-custom-urls"
  fi
  local asset
  case "${VERSION_ID:-}" in
    22.04) asset="clightning-${CLN_RELEASE_DEFAULT}-Ubuntu-22.04-amd64.tar.xz"; CLN_SHA256="$CLN_SHA256_UBUNTU_2204" ;;
    24.04) asset="clightning-${CLN_RELEASE_DEFAULT}-Ubuntu-24.04-amd64.tar.xz"; CLN_SHA256="$CLN_SHA256_UBUNTU_2404" ;;
    26.04) asset="clightning-${CLN_RELEASE_DEFAULT}-Ubuntu-26.04-amd64.tar.xz"; CLN_SHA256="$CLN_SHA256_UBUNTU_2604" ;;
    *) die "Ubuntu ${VERSION_ID:-?} non coperta dai binari upstream (22.04/24.04/26.04): usa --cln-url/--cln-sha256" ;;
  esac
  CLN_URL="https://github.com/privkeyio/lightning/releases/download/${CLN_RELEASE_DEFAULT}/${asset}"
}

# Directory dei binari CLN nel layout estratto (usr/bin o simile).
# PERCHÉ dinamico: il layout interno del tar può variare tra release.
cln_bin_dir() {
  if [[ -z "${CLN_BIN_DIR:-}" ]]; then
    local lightningd
    lightningd="$(find "$CLN_HOME" -maxdepth 4 -type f -name lightningd -print -quit 2>/dev/null || true)"
    [[ -n "$lightningd" ]] || die "lightningd non trovato in $CLN_HOME (installazione incompleta?)"
    CLN_BIN_DIR="$(dirname "$lightningd")"
  fi
  printf '%s' "$CLN_BIN_DIR"
}

# Installazione CLN (idempotente): estrae l'archivio COMPLETO.
install_cln_binaries() {
  if [[ -n "$(find "$CLN_HOME" -maxdepth 4 -type f -name lightningd -print -quit 2>/dev/null || true)" ]]; then
    log "CLN già installato in $CLN_HOME — salto il download (idempotente)"
    return 0
  fi
  local tarball="$TMP_DIR/cln.tar.xz"
  download_verified "$CLN_URL" "$CLN_SHA256" "$tarball"
  mkdir -p "$CLN_HOME" "$CLN_HOME/lib"
  # PERCHÉ estrazione COMPLETA (non solo i binari): i plugin in
  # libexec/c-lightning/plugins sono indispensabili — in particolare `bcli`
  # registra le opzioni `bitcoin-rpc*` (senza di lui lightningd le rifiuta
  # come "unknown option") e `clnrest` serve al bridge. Vedi test E2E 14/09.
  tar -xf "$tarball" -C "$CLN_HOME" || die "estrazione archivio CLN fallita"
  local ld
  ld="$(find "$CLN_HOME" -maxdepth 4 -type f -name lightningd -print -quit)"
  [[ -n "$ld" ]] || die "lightningd non trovato nell'archivio scaricato"
  CLN_BIN_DIR="$(dirname "$ld")"
  log "CLN installato in $CLN_BIN_DIR ($CLN_RELEASE_DEFAULT)"
}

# libpq5 senza sudo: apt-get download + dpkg -x (pattern collaudato).
install_libpq() {
  if compgen -G "$CLN_HOME/lib/libpq.so*" >/dev/null; then
    log "libpq già presente in $CLN_HOME/lib — salto"
    return 0
  fi
  local deb="$TMP_DIR/libpq5.deb"
  if [[ -n "${TLW_LIBPQ_DEB:-}" ]]; then
    # PERCHÉ: usato dai test/CI (offline) — non è un canale di produzione.
    log "libpq: uso pacchetto locale ($TLW_LIBPQ_DEB)"
    cp "$TLW_LIBPQ_DEB" "$deb" || die "copia libpq locale fallita"
  else
    (cd "$TMP_DIR" && apt-get download libpq5 >/dev/null 2>&1) \
      || die "apt-get download libpq5 fallito (serve accesso ai repository apt)"
    local found
    found="$(find "$TMP_DIR" -maxdepth 1 -name 'libpq5_*.deb' | head -n 1)"
    [[ -n "$found" ]] || die "pacchetto libpq5 non scaricato"
    deb="$found"
  fi
  dpkg -x "$deb" "$TMP_DIR/libpq-extract" || die "estrazione libpq5 fallita"
  find "$TMP_DIR/libpq-extract" -name 'libpq.so*' -exec cp -a {} "$CLN_HOME/lib/" \;
  log "libpq installata in $CLN_HOME/lib (user-level, senza sudo)"
}

# Scrive la config di CLN (mai sovrascritta — idempotenza).
write_cln_config() {
  mkdir -p "$LIGHTNING_DIR"
  if [[ -f "$LIGHTNING_DIR/config" ]]; then
    log "config CLN esistente: NON sovrascritta (idempotente)"
    return 0
  fi
  cat >"$LIGHTNING_DIR/config" <<EOF
network=bitcoin
alias=${NODE_ALIAS}
log-level=info
bind-addr=0.0.0.0:${CLN_P2P_PORT}
grpc-port=${CLN_GRPC_PORT}
bitcoin-rpcconnect=${BTC_RPC_HOST}
bitcoin-rpcport=${BTC_RPC_PORT}
bitcoin-rpcuser=${BTC_RPC_USER}
bitcoin-rpcpassword=${BTC_RPC_PASS}
clnrest-port=${CLNREST_PORT}
clnrest-host=127.0.0.1
clnrest-protocol=http
EOF
  # PERCHÉ 600: il file contiene le credenziali RPC del bitcoind.
  chmod 600 "$LIGHTNING_DIR/config"
  log "config CLN scritta: $LIGHTNING_DIR/config"
}

# Wrapper per lightning-cli (LD_LIBRARY_PATH per libpq estratta).
cln_cli() {
  local bindir
  bindir="$(cln_bin_dir)"
  LD_LIBRARY_PATH="$CLN_HOME/lib" "$bindir/lightning-cli" \
    --lightning-dir="$LIGHTNING_DIR" "$@"
}

# Avvia CLN: systemd --user se disponibile, altrimenti --daemon diretto.
start_cln() {
  if [[ "$SKIP_START" == "1" ]]; then
    log "avvio CLN saltato (--skip-start, solo test/CI)"
    return 0
  fi
  if systemd_available; then
    write_cln_unit
    systemctl --user enable --now cln-blake2b.service >/dev/null 2>&1 \
      || warn "systemctl --user enable --now cln-blake2b.service fallito: uso avvio diretto"
    if ! systemctl --user is-active --quiet cln-blake2b.service; then
      start_cln_direct
    fi
  else
    start_cln_direct
  fi
}

start_cln_direct() {
  log "avvio lightningd (modalità diretta, senza systemd)"
  local bindir
  bindir="$(cln_bin_dir)"
  LD_LIBRARY_PATH="$CLN_HOME/lib" "$bindir/lightningd" \
    --daemon --lightning-dir="$LIGHTNING_DIR" \
    --log-file="$LIGHTNING_DIR/lightningd.log" \
    || die "avvio lightningd fallito: guarda $LIGHTNING_DIR/lightningd.log"
}

# Attende il socket RPC e valida il backend con getinfo.
wait_cln_ready() {
  if [[ "$SKIP_START" == "1" ]]; then
    return 0
  fi
  local i=0
  while [[ ! -S "$LIGHTNING_DIR/bitcoin/lightning-rpc" ]]; do
    i=$((i + 1))
    if [[ $i -gt 30 ]]; then
      die "socket RPC non comparso entro 30s: controlla $LIGHTNING_DIR/lightningd.log"
    fi
    sleep 1
  done
  if ! cln_cli getinfo >/dev/null 2>&1; then
    die "getinfo fallito: il backend bitcoind è raggiungibile? Controlla $LIGHTNING_DIR/lightningd.log"
  fi
  log "lightningd attivo e connesso al backend (getinfo OK)"
}

# Crea la rune dedicata del bridge (mai sovrascritta).
create_rune() {
  local rune_file="$LIGHTNING_DIR/bridge-rune"
  if [[ -f "$rune_file" ]]; then
    log "rune esistente: NON ricreata ($rune_file)"
    return 0
  fi
  local json rune
  json="$(cln_cli createrune)" || die "createrune fallito (lightningd è attivo?)"
  rune="$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["rune"])')" \
    || die "estrazione della rune fallita"
  [[ -n "$rune" ]] || die "rune vuota da createrune"
  printf 'LIGHTNING_RUNE="%s"\n' "$rune" >"$rune_file"
  chmod 600 "$rune_file"
  # NB: la rune NON viene mai stampata né loggata.
  log "rune dedicata creata: $rune_file (permessi 600)"
}

# True se systemd --user è realmente funzionante (non solo il binario presente).
systemd_available() {
  if [[ "$SKIP_START" == "1" || "${NO_SYSTEMD:-0}" == "1" ]]; then
    return 1
  fi
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

write_cln_unit() {
  local unitdir="$HOME/.config/systemd/user"
  local bindir
  bindir="$(cln_bin_dir)"
  mkdir -p "$unitdir"
  cat >"$unitdir/cln-blake2b.service" <<EOF
[Unit]
Description=Core Lightning (fork blake2b) — nodo utente
After=network-online.target

[Service]
Environment=LD_LIBRARY_PATH=$CLN_HOME/lib
ExecStart=$bindir/lightningd --lightning-dir=$LIGHTNING_DIR --log-file=$LIGHTNING_DIR/lightningd.log
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

check_linger() {
  if [[ "$SKIP_START" == "1" || "${NO_SYSTEMD:-0}" == "1" ]]; then
    return 0
  fi
  if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
      warn "per far sopravvivere i servizi alla disconnessione SSH: sudo loginctl enable-linger $USER (una tantum, richiede sudo)"
    fi
  fi
}
