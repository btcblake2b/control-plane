#!/usr/bin/env bash
# Test E2E "da zero" dell'installer su un HOST REALE, in modalità ISOLATA (co-tenant).
#
# Perché così:
#  - path dedicati (--cln-home/--lightning-dir/--bridge-dir/--state-dir) → il test
#    non tocca un nodo operativo eventualmente presente sull'host;
#  - --no-systemd → nessuna unit utente creata/sovrascritta;
#  - porte custom (clnrest + P2P) → nessun conflitto con servizi esistenti.
#
# Prerequisiti:
#  - bitcoind raggiungibile via RPC locale (config passata in BTC_CONF);
#  - artifact bridge REALE in BRIDGE_SRC (la release ufficiale non è ancora pubblicata).
#
# Uso: bash run-e2e-vm.sh
set -euo pipefail

BASE="${E2E_BASE:-$HOME/e2e-test}"
INST="$BASE/installer"
BTC_CONF="${BTC_CONF:-$HOME/.bitcoin/bitcoin.conf}"
BRIDGE_SRC="${BRIDGE_SRC:-$HOME/bridge/bridge-exe}"
CLNREST_PORT="${CLNREST_PORT:-3011}"
P2P_PORT="${P2P_PORT:-19735}"
GRPC_PORT="${GRPC_PORT:-19736}"

step() { echo; echo "== $* =="; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "1. pulizia dell'ambiente di test"
rm -rf "$BASE/cln-blake2b" "$BASE/lightning" "$BASE/bridge" "$BASE/state"
mkdir -p "$BASE"
[[ -x "$INST/install.sh" ]] || fail "installer non trovato in $INST"
[[ -f "$BTC_CONF" ]] || fail "bitcoin.conf non trovato: $BTC_CONF"
[[ -x "$BRIDGE_SRC" ]] || fail "artifact bridge non trovato: $BRIDGE_SRC"

step "2. credenziali RPC (lette ma mai stampate)"
RPCU="$(sed -n 's/^rpcuser=//p' "$BTC_CONF" | head -n 1)"
RPCP="$(sed -n 's/^rpcpassword=//p' "$BTC_CONF" | head -n 1)"
[[ -n "$RPCU" && -n "$RPCP" ]] || fail "rpcuser/rpcpassword mancanti in $BTC_CONF"

step "3. artifact bridge reale"
BR_SHA="$(sha256sum "$BRIDGE_SRC" | awk '{print $1}')"
echo "bridge artifact: $BRIDGE_SRC (sha256 ${BR_SHA:0:12}…)"

COMMON=(--no-systemd --allow-custom-urls
  --bitcoind-rpc "$RPCU:$RPCP@127.0.0.1:8332"
  --bridge-url "file://$BRIDGE_SRC" --bridge-sha256 "$BR_SHA"
  --cln-home "$BASE/cln-blake2b"
  --lightning-dir "$BASE/lightning"
  --bridge-dir "$BASE/bridge"
  --state-dir "$BASE/state"
  --clnrest-port "$CLNREST_PORT" --cln-p2p-port "$P2P_PORT" --cln-grpc-port "$GRPC_PORT")

step "4. dry-run"
"$INST/install.sh" --dry-run "${COMMON[@]}" >"$BASE/dry.out" 2>&1 || { tail -n 20 "$BASE/dry.out"; fail "dry-run"; }
grep -q "Piano di installazione" "$BASE/dry.out" || fail "piano mancante nel dry-run"
echo "dry-run OK ($(grep -c . "$BASE/dry.out") righe di piano)"

step "5. installazione reale (l'esperienza utente)"
"$INST/install.sh" "${COMMON[@]}" >"$BASE/install.out" 2>&1 \
  || { tail -n 40 "$BASE/install.out" | grep -v "nostr+walletconnect"; fail "installazione"; }
echo "installazione completata (output completo in $BASE/install.out)"

step "6. verifiche"
CLNBIN="$(dirname "$(find "$BASE/cln-blake2b" -maxdepth 4 -type f -name lightningd -print -quit 2>/dev/null || true)")"
[[ -n "$CLNBIN" && -x "$CLNBIN/lightningd" ]] || fail "lightningd non installato (layout inatteso)"
echo "OK: lightningd installato in $CLNBIN"
if find "$BASE/cln-blake2b" -maxdepth 5 -type f -name bcli -print -quit 2>/dev/null | grep -q .; then
  echo "OK: plugin bcli presente (opzioni bitcoin-rpc* registrabili)"
else
  fail "plugin bcli assente: struttura CLN incompleta"
fi
[[ -f "$BASE/lightning/config" ]] || fail "config CLN mancante"
grep -q "clnrest-port=$CLNREST_PORT" "$BASE/lightning/config" || fail "porta clnrest custom assente"
grep -q "bind-addr=0.0.0.0:$P2P_PORT" "$BASE/lightning/config" || fail "bind-addr custom assente"
grep -q "grpc-port=$GRPC_PORT" "$BASE/lightning/config" || fail "porta grpc custom assente"
echo "OK: config CLN con porte custom ($CLNREST_PORT / $P2P_PORT)"
[[ -f "$BASE/lightning/bridge-rune" ]] || fail "rune mancante"
echo "OK: rune dedicata creata"
[[ -f "$BASE/bridge/config.json" ]] || fail "config bridge mancante"
[[ -f "$BASE/bridge/uri.txt" ]] || fail "URI mancante"
echo "OK: bridge configurato e URI generata (non stampata qui)"
if LD_LIBRARY_PATH="$BASE/cln-blake2b/lib" "$CLNBIN/lightning-cli" \
     --lightning-dir="$BASE/lightning" getinfo 2>/dev/null | head -c 400; then
  echo
  echo "OK: lightningd risponde (sync in background: atteso su un nodo nuovo)"
else
  fail "getinfo non risponde"
fi

step "7. fermo i servizi di test (i file restano per ispezione)"
"$BASE/bridge/run.sh" stop >/dev/null 2>&1 || true
LD_LIBRARY_PATH="$BASE/cln-blake2b/lib" "$CLNBIN/lightning-cli" \
  --lightning-dir="$BASE/lightning" stop >/dev/null 2>&1 || true
if pgrep -af "lightningd --lightning-dir=$BASE" >/dev/null 2>&1; then
  echo "ATTENZIONE: lightningd di test risulta ancora attivo (controllare manualmente)"
else
  echo "OK: nodo di test fermato"
fi

echo
echo "===== E2E COMPLETATO ====="
