#!/usr/bin/env bash
# Registrazione del nodo verso il control plane (modello OUTBOUND).
# Il control plane non ha mai accesso a questo server: siamo noi a contattarlo.

# Uso: register_node (richiede REGISTER_TOKEN, CONTROL_PLANE_URL, BRIDGE_PUBKEY)
register_node() {
  [[ -n "$REGISTER_TOKEN" ]] || die "manca --register-token"
  [[ -n "$CONTROL_PLANE_URL" ]] || die "manca --control-plane URL"
  [[ -n "$BRIDGE_PUBKEY" ]] || die "pubkey del bridge non disponibile: esegui prima l'installazione (o --gen-uri)"

  local body tmp code
  body="$(python3 - "$REGISTER_TOKEN" "$BRIDGE_PUBKEY" "$RELAY" "$NODE_ALIAS" "$INSTALLER_VERSION" <<'PY_CODE'
import json
import sys

token, pubkey, relay, alias, version = sys.argv[1:6]
print(json.dumps({
    "token": token,
    "bridgePubkey": pubkey,
    "relay": relay,
    "alias": alias,
    "version": version,
}))
PY_CODE
)"
  tmp="$(mktemp)"
  code="$(curl --silent --show-error --output "$tmp" --write-out '%{http_code}' \
    --header 'Content-Type: application/json' --data "$body" \
    "${CONTROL_PLANE_URL%/}/v1/register")" \
    || die "richiesta al control plane fallita ($CONTROL_PLANE_URL): raggiungibile?"

  case "$code" in
    201)
      mkdir -p "$NODE_STATE_DIR"
      chmod 700 "$NODE_STATE_DIR"
      python3 - "$tmp" "$NODE_STATE_DIR/node.json" "$CONTROL_PLANE_URL" <<'PY_CODE'
import json
import sys

resp_path, out_path, cp_url = sys.argv[1], sys.argv[2], sys.argv[3]
with open(resp_path, encoding="utf-8") as fh:
    resp = json.load(fh)
data = {
    "nodeId": resp["nodeId"],
    "secret": resp["nodeSecret"],
    "controlPlane": cp_url,
    "createdAt": resp.get("createdAt", ""),
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY_CODE
      # PERCHÉ 600: node.json contiene il node_secret (credenziale verso il CP).
      chmod 600 "$NODE_STATE_DIR/node.json"
      log "nodo registrato: $NODE_STATE_DIR/node.json (secret con permessi 600)"
      ;;
    401)
      die "token non riconosciuto dal control plane: controlla di averlo copiato esattamente (64 hex)"
      ;;
    409)
      die "nodo già registrato su questo control plane: chiedi all'operatore il recovery (admin node delete) e riprova con un nuovo token"
      ;;
    410)
      die "token scaduto o già utilizzato: chiedi un nuovo token all'operatore (admin token create)"
      ;;
    *)
      die "registrazione rifiutata dal control plane (HTTP $code): $(cat "$tmp")"
      ;;
  esac
}

# Modalità --register differita: ricostruisce relay e pubkey dallo stato locale.
mode_register() {
  [[ -f "$BRIDGE_DIR/config.json" ]] || die "bridge non configurato: esegui prima l'installazione completa"
  RELAY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["relay"])' "$BRIDGE_DIR/config.json")" \
    || die "lettura relay dalla config bridge fallita"
  if [[ -f "$BRIDGE_DIR/uri.txt" ]]; then
    local pub
    pub="$(sed -n 's#^nostr+walletconnect://\([0-9a-f]\{64\}\).*#\1#p' "$BRIDGE_DIR/uri.txt")"
    if [[ -n "$pub" ]]; then
      BRIDGE_PUBKEY="$pub"
    fi
  fi
  register_node
}

# Modalità --status: stato locale + ping del control plane.
mode_status() {
  log "== stato nodo =="
  if [[ -f "$BRIDGE_DIR/run.sh" ]]; then
    "$BRIDGE_DIR/run.sh" status || true
  fi
  if [[ -n "$(find "$CLN_HOME" -maxdepth 4 -type f -name lightning-cli -print -quit 2>/dev/null || true)" ]]; then
    if cln_cli getinfo >/dev/null 2>&1; then
      log "CLN: attivo"
    else
      log "CLN: non attivo (o non ancora sincronizzato)"
    fi
  fi
  if [[ -f "$NODE_STATE_DIR/node.json" ]]; then
    local nodeid secret cp tmp code
    nodeid="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["nodeId"])' "$NODE_STATE_DIR/node.json")"
    secret="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["secret"])' "$NODE_STATE_DIR/node.json")"
    cp="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["controlPlane"])' "$NODE_STATE_DIR/node.json")"
    tmp="$(mktemp)"
    code="$(curl -s -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer $secret" \
      "${cp%/}/v1/nodes/$nodeid")" || code="000"
    case "$code" in
      200) log "control plane: nodo registrato (HTTP 200)" ;;
      404) warn "control plane: nodo NON trovato (record rimosso? riregistra con un nuovo token)" ;;
      401) warn "control plane: credenziale rifiutata (secret ruotato altrove? usa --rotate-secret)" ;;
      000) warn "control plane: non raggiungibile" ;;
      *) warn "control plane: risposta inattesa (HTTP $code)" ;;
    esac
  else
    log "nodo NON registrato (manca $NODE_STATE_DIR/node.json)"
  fi
  if [[ -f "$BRIDGE_DIR/config.json" ]]; then
    local count
    count="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("allowedClientPubkeys",[])))' "$BRIDGE_DIR/config.json")"
    log "client autorizzati nel bridge: $count"
  fi
}

# Modalità --revoke-client PUBKEY: rimuove la pubkey dall'allowlist + restart.
mode_revoke_client() {
  local client_pub="$1"
  require_hex64 "$client_pub" "pubkey del client"
  [[ -f "$BRIDGE_DIR/config.json" ]] || die "config bridge non trovata: nulla da revocare"
  local result
  result="$(python3 - "$BRIDGE_DIR/config.json" "$client_pub" <<'PY_CODE'
import json
import sys

path, pub = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
allowed = cfg.get("allowedClientPubkeys", [])
if pub in allowed:
    allowed.remove(pub)
    cfg["allowedClientPubkeys"] = allowed
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
    print("rimossa")
else:
    print("non-presente")
PY_CODE
)"
  case "$result" in
    rimossa)
      restart_bridge_if_running
      log "client revocato: la sua URI non è più autorizzata dal bridge"
      ;;
    non-presente)
      warn "pubkey non presente nell'allowlist: nessuna modifica"
      ;;
    *) die "revoca fallita" ;;
  esac
}

# Modalità --rotate-secret: nuovo node_secret tramite il control plane.
mode_rotate_secret() {
  [[ -f "$NODE_STATE_DIR/node.json" ]] || die "nodo non registrato ($NODE_STATE_DIR/node.json assente)"
  local nodeid secret cp tmp code
  nodeid="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["nodeId"])' "$NODE_STATE_DIR/node.json")"
  secret="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["secret"])' "$NODE_STATE_DIR/node.json")"
  cp="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["controlPlane"])' "$NODE_STATE_DIR/node.json")"
  tmp="$(mktemp)"
  code="$(curl -s -o "$tmp" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $secret" \
    "${cp%/}/v1/nodes/$nodeid/rotate-secret")" || die "richiesta al control plane fallita"
  [[ "$code" == "200" ]] || die "rotazione rifiutata dal control plane (HTTP $code): $(cat "$tmp")"
  python3 - "$tmp" "$NODE_STATE_DIR/node.json" <<'PY_CODE'
import json
import sys

resp_path, state_path = sys.argv[1], sys.argv[2]
with open(resp_path, encoding="utf-8") as fh:
    resp = json.load(fh)
with open(state_path, encoding="utf-8") as fh:
    data = json.load(fh)
data["secret"] = resp["nodeSecret"]
with open(state_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY_CODE
  chmod 600 "$NODE_STATE_DIR/node.json"
  log "node_secret ruotato: le copie del vecchio secret non funzionano più"
}
