#!/usr/bin/env bash
# Setup del bridge NWC/NCC (binario AOT) — user-level, senza sudo.
# Esporta: BRIDGE_PUBKEY (pubkey Nostr del bridge, dalla URI generata)

# Installa il binario del bridge (idempotente).
install_bridge_binary() {
  mkdir -p "$BRIDGE_DIR"
  if [[ -x "$BRIDGE_DIR/bridge-exe" ]]; then
    log "bridge già presente in $BRIDGE_DIR — salto il download (idempotente)"
    return 0
  fi
  download_verified "$BRIDGE_URL" "$BRIDGE_SHA256" "$BRIDGE_DIR/bridge-exe"
  chmod 755 "$BRIDGE_DIR/bridge-exe"
  log "binario bridge installato: $BRIDGE_DIR/bridge-exe"
}

# Config del bridge (mai sovrascritta — idempotenza; permessi 600).
write_bridge_config() {
  local cfg="$BRIDGE_DIR/config.json"
  if [[ -f "$cfg" ]]; then
    log "config bridge esistente: NON sovrascritta (idempotente)"
    return 0
  fi
  local privkey
  privkey="$("$BRIDGE_DIR/bridge-exe" --genkey)" || die "--genkey del bridge fallito"
  privkey="$(printf '%s' "$privkey" | tr -d '[:space:]')"
  [[ "$privkey" =~ ^[0-9a-f]{64}$ ]] || die "--genkey ha restituito una chiave non valida"
  python3 - "$cfg" "$RELAY" "$privkey" "$LIGHTNING_DIR" "$CLNREST_PORT" <<'PY_CODE'
import json
import sys

cfg_path, relay, privkey, lightning_dir, clnrest_port = (
    sys.argv[1],
    sys.argv[2],
    sys.argv[3],
    sys.argv[4],
    sys.argv[5],
)
config = {
    "relay": relay,
    "privkeyHex": privkey,
    # PERCHÉ parametrizzato: clnrest può essere su porta custom (--clnrest-port,
    # co-tenant). Con 3001 hardcoded il bridge parla con un ALTRO nodo → l'app
    # riceve RESTRICTED ("il nodo non ha autorizzato questa app"). Bug trovato
    # nel test con app reale del 14/09/2026.
    "clnUrl": f"http://127.0.0.1:{clnrest_port}",
    "runeFile": f"{lightning_dir}/bridge-rune",
    "alias": "btcblake2b-bridge",
    "allowedClientPubkeys": [],
    "logLevel": "info",
}
with open(cfg_path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, indent=2)
PY_CODE
  # PERCHÉ 600: il file contiene la chiave privata Nostr del bridge.
  chmod 600 "$cfg"
  log "config bridge scritta: $cfg (permessi 600)"
}

# Genera l'URI NWC/NCC (la secret va all'utente; MAI nei log).
generate_bridge_uri() {
  local out uri pubkey
  out="$("$BRIDGE_DIR/bridge-exe" --genuri --config="$BRIDGE_DIR/config.json")" \
    || die "--genuri del bridge fallito"
  uri="$(printf '%s\n' "$out" | sed -n 's#^\(nostr+walletconnect://[^[:space:]]*\)$#\1#p' | head -n 1)"
  [[ -n "$uri" ]] || die "URI non trovata nell'output di --genuri"
  pubkey="$(printf '%s' "$uri" | sed -n 's#^nostr+walletconnect://\([0-9a-f]\{64\}\).*#\1#p')"
  [[ -n "$pubkey" ]] || die "pubkey del bridge non estraibile dalla URI"
  printf '%s\n' "$uri" >"$BRIDGE_DIR/uri.txt"
  chmod 600 "$BRIDGE_DIR/uri.txt"
  BRIDGE_PUBKEY="$pubkey"
  log "URI NWC/NCC generata e salvata in $BRIDGE_DIR/uri.txt"
}

# Riusa l'URI esistente; la genera solo se manca (re-run idempotente).
# PERCHÉ: ogni --genuri aggiunge un client all'allowlist del bridge — un
# re-run dell'installer non deve creare client fantasma né cambiare la URI
# già consegnata all'utente (per un nuovo telefono: --gen-uri esplicito).
ensure_bridge_uri() {
  if [[ -f "$BRIDGE_DIR/uri.txt" ]]; then
    local pub
    pub="$(sed -n 's#^nostr+walletconnect://\([0-9a-f]\{64\}\).*#\1#p' "$BRIDGE_DIR/uri.txt")"
    if [[ -n "$pub" ]]; then
      BRIDGE_PUBKEY="$pub"
      log "URI esistente trovata: NON rigenerata (usa --gen-uri per un nuovo client)"
      return 0
    fi
    warn "uri.txt illeggibile: la rigenero"
  fi
  generate_bridge_uri
}

# Modalità --gen-uri: autorizza un nuovo client su un'installazione esistente.
mode_gen_uri() {
  [[ -f "$BRIDGE_DIR/config.json" ]] || die "bridge non configurato: esegui prima l'installazione"
  generate_bridge_uri
  print_bridge_uri
  log "nuovo client autorizzato: incolla la URI in un'app (revoca: --revoke-client <pubkey>)"
}

# run.sh con pidfile (lezione appresa: i binari AOT hanno comm diverso dal nome).
write_bridge_run_sh() {
  cat >"$BRIDGE_DIR/run.sh" <<'RUN_EOF'
#!/usr/bin/env bash
# Gestione del processo bridge — pidfile per evitare istanze multiple.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$DIR/bridge.pid"
case "${1:-}" in
  start)
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "bridge già in esecuzione (pid $(cat "$PIDFILE"))"; exit 0
    fi
    setsid nohup "$DIR/bridge-exe" --config="$DIR/config.json" >>"$DIR/bridge.log" 2>&1 &
    echo $! >"$PIDFILE"
    echo "bridge avviato (pid $(cat "$PIDFILE"))"
    ;;
  stop)
    if [[ -f "$PIDFILE" ]]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "bridge arrestato"
    else
      echo "bridge non in esecuzione"
    fi
    ;;
  status)
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "bridge attivo (pid $(cat "$PIDFILE"))"
    else
      echo "bridge non attivo"; exit 1
    fi
    ;;
  *)
    echo "uso: run.sh start|stop|status"; exit 2 ;;
esac
RUN_EOF
  chmod 755 "$BRIDGE_DIR/run.sh"
}

# Avvia il bridge: systemd --user se disponibile, altrimenti run.sh.
start_bridge() {
  if [[ "$SKIP_START" == "1" ]]; then
    log "avvio bridge saltato (--skip-start, solo test/CI)"
    return 0
  fi
  if systemd_available; then
    write_bridge_unit
    systemctl --user enable --now bridge.service >/dev/null 2>&1 \
      || warn "systemctl --user enable --now bridge.service fallito: uso run.sh"
    if ! systemctl --user is-active --quiet bridge.service; then
      "$BRIDGE_DIR/run.sh" start || warn "avvio bridge fallito: guarda $BRIDGE_DIR/bridge.log"
    fi
  else
    "$BRIDGE_DIR/run.sh" start || warn "avvio bridge fallito: guarda $BRIDGE_DIR/bridge.log"
  fi
}

write_bridge_unit() {
  local unitdir="$HOME/.config/systemd/user"
  mkdir -p "$unitdir"
  cat >"$unitdir/bridge.service" <<EOF
[Unit]
Description=Bridge NWC/NCC (bitcoin-blake2b)
After=cln-blake2b.service

[Service]
ExecStart=$BRIDGE_DIR/bridge-exe --config=$BRIDGE_DIR/config.json
WorkingDirectory=$BRIDGE_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

restart_bridge_if_running() {
  if [[ "$SKIP_START" == "1" ]]; then
    return 0
  fi
  if systemd_available && systemctl --user is-active --quiet bridge.service 2>/dev/null; then
    systemctl --user restart bridge.service || warn "restart del bridge fallito"
  elif [[ -x "$BRIDGE_DIR/run.sh" ]]; then
    "$BRIDGE_DIR/run.sh" stop >/dev/null 2>&1 || true
    "$BRIDGE_DIR/run.sh" start >/dev/null 2>&1 || warn "riavvio del bridge fallito"
  fi
}

# Stampa URI + QR (la URI contiene un segreto: SOLO terminale, mai log).
print_bridge_uri() {
  [[ -f "$BRIDGE_DIR/uri.txt" ]] || return 0
  local uri
  uri="$(cat "$BRIDGE_DIR/uri.txt")"
  printf '\nURI NWC/NCC (contiene un segreto: NON condividerla):\n\n  %s\n\n' "$uri"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$uri"
  else
    printf '(per il QR: sudo apt install qrencode; poi: qrencode -t ANSIUTF8 %s/uri.txt)\n' "$BRIDGE_DIR"
  fi
}
