#!/usr/bin/env bash
# Verifiche post-E2E su host reale (ambiente isolato in ~/e2e-test).
# Copre: output utente, log bridge, idempotenza (re-run), --status, uninstall isolato.
set -euo pipefail

BASE="${E2E_BASE:-$HOME/e2e-test}"
INST="$BASE/installer"
ACTIVE="$BASE/cln-blake2b/usr/bin"
RPCU="$(sed -n 's/^bitcoin-rpcuser=//p' "$BASE/lightning/config" | head -n 1)"
RPCP="$(sed -n 's/^bitcoin-rpcpassword=//p' "$BASE/lightning/config" | head -n 1)"

step() { echo; echo "== $* =="; }

step "A. output utente dell'installazione (URI filtrata)"
grep -v nostr+walletconnect "$BASE/install.out" | tail -n 40

step "B. log del bridge (eventi recenti)"
tail -n 8 "$BASE/bridge/bridge.log" 2>/dev/null || echo "(nessun bridge.log)"

step "C. re-run idempotente (salta download, NON riscrive config)"
CFG1="$(sha256sum "$BASE/lightning/config" | awk '{print $1}')"
BR1="$(sha256sum "$BASE/bridge/config.json" | awk '{print $1}')"
URI1="$(sha256sum "$BASE/bridge/uri.txt" | awk '{print $1}')"
"$INST/install.sh" --no-systemd --allow-custom-urls \
  --bitcoind-rpc "$RPCU:$RPCP@127.0.0.1:8332" \
  --bridge-url "file://$HOME/bridge/bridge-exe" \
  --bridge-sha256 "$(sha256sum "$HOME/bridge/bridge-exe" | awk '{print $1}')" \
  --cln-home "$BASE/cln-blake2b" --lightning-dir "$BASE/lightning" \
  --bridge-dir "$BASE/bridge" --state-dir "$BASE/state" \
  --clnrest-port 3011 --cln-p2p-port 19735 --cln-grpc-port 19736 \
  >"$BASE/install2.out" 2>&1 || { tail -n 30 "$BASE/install2.out" | grep -v nostr+walletconnect; exit 1; }
CFG2="$(sha256sum "$BASE/lightning/config" | awk '{print $1}')"
BR2="$(sha256sum "$BASE/bridge/config.json" | awk '{print $1}')"
URI2="$(sha256sum "$BASE/bridge/uri.txt" | awk '{print $1}')"
if [[ "$CFG1" == "$CFG2" ]]; then echo "OK: config CLN NON riscritta"; else echo "FAIL: config CLN riscritta!"; fi
if [[ "$BR1" == "$BR2" ]]; then echo "OK: config bridge NON riscritta"; else echo "FAIL: config bridge riscritta!"; fi
if [[ "$URI1" == "$URI2" ]]; then echo "OK: URI NON rigenerata"; else echo "FAIL: URI rigenerata!"; fi

step "D. --status"
"$INST/install.sh" --status \
  --cln-home "$BASE/cln-blake2b" --lightning-dir "$BASE/lightning" \
  --bridge-dir "$BASE/bridge" --state-dir "$BASE/state" 2>&1 | tail -n 12 || true

step "E. stop servizi"
"$BASE/bridge/run.sh" stop >/dev/null 2>&1 || true
LD_LIBRARY_PATH="$BASE/cln-blake2b/lib" "$ACTIVE/lightning-cli" \
  --lightning-dir="$BASE/lightning" stop >/dev/null 2>&1 || true
echo "servizi di test fermati"

step "F. uninstall isolato (datadir di test INTATTO)"
"$INST/install.sh" --uninstall --yes \
  --cln-home "$BASE/cln-blake2b" --lightning-dir "$BASE/lightning" \
  --bridge-dir "$BASE/bridge" --state-dir "$BASE/state" 2>&1 | tail -n 6 || true
if [[ ! -d "$BASE/cln-blake2b" ]]; then echo "OK: cln-home di test rimosso"; else echo "FAIL: cln-home ancora presente"; fi
if [[ -d "$BASE/lightning" ]]; then echo "OK: datadir di test intatto"; else echo "FAIL: datadir rimosso!"; fi

echo
echo "===== VERIFICA COMPLETATA ====="
