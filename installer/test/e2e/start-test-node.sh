#!/usr/bin/env bash
# Avvia (o riavvia) il nodo di TEST gia installato, per prove manuali con l'app.
#
# PERCHE': run-e2e-vm.sh fa rm -rf del datadir (test "da zero"). Questo script
# invece RIUSA il datadir esistente (stesso node id / hsm_secret) e reinstalla
# solo cio che serve: binari CLN, bridge e relativa config/URI.
# Non tocca MAI il datadir: niente rm -rf su $BASE/lightning.
#
# Uso: bash start-test-node.sh   (sul server, dentro ~/e2e-test)
# Variabili: E2E_BASE, BTC_CONF, BRIDGE_SRC, CLNREST_PORT, P2P_PORT, GRPC_PORT
set -euo pipefail

BASE="${E2E_BASE:-$HOME/e2e-test}"
INST="$BASE/installer"
BTC_CONF="${BTC_CONF:-/media/filippo/bitcoin2/blockchain/bitcoin.conf}"
BRIDGE_SRC="${BRIDGE_SRC:-$HOME/bridge/bridge-exe}"
CLNREST_PORT="${CLNREST_PORT:-3011}"
P2P_PORT="${P2P_PORT:-19735}"
GRPC_PORT="${GRPC_PORT:-19736}"

step() { echo; echo "== $* =="; }

step "1. prerequisiti"
[[ -x "$INST/install.sh" ]] || { echo "FAIL: installer non trovato in $INST"; exit 1; }
[[ -f "$BTC_CONF" ]] || { echo "FAIL: bitcoin.conf non trovato: $BTC_CONF"; exit 1; }
[[ -x "$BRIDGE_SRC" ]] || { echo "FAIL: artifact bridge non trovato: $BRIDGE_SRC"; exit 1; }
if [[ -d "$BASE/lightning" ]]; then
  echo "datadir esistente: $BASE/lightning (verra RIUSATO, stesso node id)"
else
  echo "WARN: datadir assente: sara una installazione nuova"
fi

step "2. credenziali RPC (lette ma mai stampate)"
RPCU="$(sed -n 's/^rpcuser=//p' "$BTC_CONF" | head -n 1)"
RPCP="$(sed -n 's/^rpcpassword=//p' "$BTC_CONF" | head -n 1)"
[[ -n "$RPCU" && -n "$RPCP" ]] || { echo "FAIL: rpcuser/rpcpassword mancanti in $BTC_CONF"; exit 1; }

step "3. artifact bridge reale"
BR_SHA="$(sha256sum "$BRIDGE_SRC" | awk '{print $1}')"
echo "bridge artifact: $BRIDGE_SRC (sha256 ${BR_SHA:0:12}...)"

# Stesse opzioni dell'E2E: co-tenant (path e porte dedicati) e senza systemd.
COMMON=(--no-systemd --allow-custom-urls
  --bitcoind-rpc "$RPCU:$RPCP@127.0.0.1:8332"
  --bridge-url "file://$BRIDGE_SRC" --bridge-sha256 "$BR_SHA"
  --cln-home "$BASE/cln-blake2b"
  --lightning-dir "$BASE/lightning"
  --bridge-dir "$BASE/bridge"
  --state-dir "$BASE/state"
  --clnrest-port "$CLNREST_PORT" --cln-p2p-port "$P2P_PORT" --cln-grpc-port "$GRPC_PORT")

step "4. installazione/avvio (idempotente: datadir e config NON riscritti)"
"$INST/install.sh" "${COMMON[@]}" >"$BASE/install-app-test.out" 2>&1 \
  || { tail -n 40 "$BASE/install-app-test.out" | grep -v "nostr+walletconnect"; exit 1; }
echo "completato (output in $BASE/install-app-test.out)"

step "5. verifiche rapide"
CLNBIN="$(dirname "$(find "$BASE/cln-blake2b" -maxdepth 4 -type f -name lightningd -print -quit 2>/dev/null || true)")"
if [[ -n "$CLNBIN" && -x "$CLNBIN/lightning-cli" ]]; then
  if "$CLNBIN/lightning-cli" --lightning-dir="$BASE/lightning" getinfo >/dev/null 2>&1; then
    echo "OK: lightningd risponde (getinfo)"
  else
    echo "WARN: lightningd non risponde ancora (sync iniziale su nodo nuovo?)"
  fi
else
  echo "FAIL: lightning-cli non trovato"
fi
if pgrep -f "$BASE/bridge/bridge-exe" >/dev/null 2>&1; then
  echo "OK: bridge di test attivo"
else
  echo "WARN: bridge di test non attivo (vedi $BASE/install-app-test.out)"
fi

step "6. URI per l'app (segreta: valida solo per questo nodo di test)"
if [[ -f "$BASE/bridge/uri.txt" ]]; then
  echo
  cat "$BASE/bridge/uri.txt"
  echo
  echo "(per revocarla: install.sh --revoke-client <pubkey>)"
else
  echo "FAIL: uri.txt mancante"
  exit 1
fi
