#!/usr/bin/env bash
# Smoke test di RELEASE: scarica il pacchetto dalla GitHub Release reale e
# installa in co-tenant pulito usando i PIN di default (NESSUN override).
#
# PERCHÉ: valida esattamente ciò che scaricherà l'utente finale — asset reali
# (tarball + bridge) e checksum pinnati — non artifact locali dei test Docker.
#
# Uso: RELEASE=v0.1.0 bash smoke-release.sh   (sul server Linux, con bitcoind RPC)
set -euo pipefail

REL="${RELEASE:-v0.1.0}"
PKG_VER="${PKG_VER:-0.1.0}"
BASE="${SMOKE_BASE:-$HOME/e2e-release-test}"
BTC_CONF="${BTC_CONF:-/media/filippo/bitcoin2/blockchain/bitcoin.conf}"
GH="https://github.com/btcblake2b/control-plane/releases/download/$REL"

step() { echo; echo "== $* =="; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "1. ambiente pulito: $BASE"
rm -rf "$BASE"
mkdir -p "$BASE"
cd "$BASE"

step "2. download dalla release reale ($REL)"
curl -fsSLO "$GH/tlw-node-installer-$PKG_VER.tar.gz"
curl -fsSLO "$GH/SHA256SUMS"
sha256sum -c SHA256SUMS --ignore-missing || fail "checksum del pacchetto"
tar -xzf "tlw-node-installer-$PKG_VER.tar.gz"
cd "tlw-node-installer-$PKG_VER"
echo "OK: pacchetto scaricato e verificato"

step "3. install con i PIN di default (niente --bridge-url/--allow-custom-urls)"
RPCU="$(sed -n 's/^rpcuser=//p' "$BTC_CONF" | head -n 1)"
RPCP="$(sed -n 's/^rpcpassword=//p' "$BTC_CONF" | head -n 1)"
[[ -n "$RPCU" && -n "$RPCP" ]] || fail "credenziali RPC mancanti in $BTC_CONF"
./install.sh --no-systemd \
  --bitcoind-rpc "$RPCU:$RPCP@127.0.0.1:8332" \
  --clnrest-port 3012 --cln-p2p-port 19737 --cln-grpc-port 19738 \
  --cln-home "$BASE/cln-blake2b" --lightning-dir "$BASE/lightning" \
  --bridge-dir "$BASE/bridge" --state-dir "$BASE/state" \
  >"$BASE/install.out" 2>&1 \
  || { tail -n 40 "$BASE/install.out" | grep -v "nostr+walletconnect"; fail "installazione"; }
echo "OK: installazione completata (output in $BASE/install.out)"

step "4. verifiche"
# Prova DIRETTA del pin: l'hash del binario installato deve essere quello pinnato.
PIN="$(sed -n 's/^BRIDGE_SHA256_DEFAULT="\([0-9a-f]*\)"$/\1/p' install.sh)"
ACT="$(sha256sum "$BASE/bridge/bridge-exe" | awk '{print $1}')"
[[ -n "$PIN" && "$PIN" == "$ACT" ]] || fail "bridge installato diverso dal pin ($ACT)"
echo "OK: bridge installato = asset pinnato della release (${PIN:0:12}…)"
CLNBIN="$(dirname "$(find "$BASE/cln-blake2b" -maxdepth 4 -type f -name lightningd -print -quit)")"
LD_LIBRARY_PATH="$BASE/cln-blake2b/lib" "$CLNBIN/lightning-cli" \
  --lightning-dir="$BASE/lightning" getinfo >/dev/null && echo "OK: nodo risponde (getinfo)"
if pgrep -f "$BASE/bridge/bridge-exe" >/dev/null; then
  echo "OK: bridge di release attivo"
else
  fail "bridge non attivo"
fi
grep clnUrl "$BASE/bridge/config.json"
[[ -f "$BASE/bridge/uri.txt" ]] && echo "OK: URI generata ($(wc -c <"$BASE/bridge/uri.txt") byte)"
echo "bridge log (ultime 3 righe):"
tail -n 3 "$BASE/bridge/bridge.log" 2>/dev/null || true

step "5. fermo i servizi di smoke (i file restano per ispezione)"
"$BASE/bridge/run.sh" stop >/dev/null 2>&1 || true
LD_LIBRARY_PATH="$BASE/cln-blake2b/lib" "$CLNBIN/lightning-cli" \
  --lightning-dir="$BASE/lightning" stop >/dev/null 2>&1 || true
echo "OK: servizi fermati"

echo
echo "===== SMOKE RELEASE $REL COMPLETATO ====="
