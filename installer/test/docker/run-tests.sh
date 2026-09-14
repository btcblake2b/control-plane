#!/usr/bin/env bash
# Test di integrazione dell'installer — eseguito DENTRO un container Docker.
# Copre: shellcheck, dry-run, fail-closed checksum, install con artifact
# locali, idempotenza, registrazione (mock control plane), token scaduto,
# uninstall con datadir intatto.
set -euo pipefail

INSTALLER=/opt/installer/install.sh
WORK=/tmp/tlw-test
export HOME=/root

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "OK: $*"
}

echo "== 0) shellcheck =="
# -e SC2034: variabili condivise tra moduli (uso cross-file, dopo il source).
# -e SC1091: i source usano path dinamici ($SCRIPT_DIR), non risolvibili staticamente.
cd /opt/installer
shellcheck -x -e SC2034,SC1091 "$INSTALLER" lib/*.sh test/docker/run-tests.sh \
  || fail "shellcheck"
pass "shellcheck"

echo "== 0b) release readiness: pin bridge attivo =="
# PERCHÉ: senza pin il pacchetto non è pubblicabile (l'installer abortisce su
# ogni macchina utente senza override test/CI). Guard sul rilascio.
grep -Eq '^BRIDGE_SHA256_DEFAULT="[0-9a-f]{64}"$' "$INSTALLER" \
  || fail "pin bridge non attivo: release non pubblicabile"
pass "release readiness"

rm -rf "$WORK" /root/cln-blake2b /root/bridge /root/.tlw-node /root/.lightning
mkdir -p "$WORK/artifacts"

echo "== 1) preparazione artifact finti =="
mkdir -p "$WORK/fakecln/usr/bin" "$WORK/fakecln/usr/libexec/c-lightning/plugins"
cat >"$WORK/fakecln/usr/bin/lightningd" <<'EOF'
#!/usr/bin/env bash
echo "fake-lightningd (test)"; exit 0
EOF
cat >"$WORK/fakecln/usr/bin/lightning-cli" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    createrune) echo '{"rune":"FAKE-RUNE-TEST-ONLY","unique_id":"fake"}'; exit 0 ;;
    getinfo) echo '{"id":"02fake","blockheight":1,"network":"bitcoin"}'; exit 0 ;;
    stop) echo '{"result":"stopped"}'; exit 0 ;;
  esac
done
echo '{"ok":true}'
EOF
cat >"$WORK/fakecln/usr/bin/lightning-hsmtool" <<'EOF'
#!/usr/bin/env bash
echo "fake-hsmtool (test)"; exit 0
EOF
# Plugin finti: la suite verifica che l'estrazione preservi usr/libexec (bcli/clnrest).
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/fakecln/usr/libexec/c-lightning/plugins/bcli"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/fakecln/usr/libexec/c-lightning/plugins/clnrest"
chmod +x "$WORK/fakecln/usr/bin/"* "$WORK/fakecln/usr/libexec/c-lightning/plugins/"*
tar -cJf "$WORK/artifacts/cln.tar.xz" -C "$WORK/fakecln" .

cat >"$WORK/artifacts/bridge-exe" <<'EOF'
#!/usr/bin/env bash
# Fake bridge (solo per test): supporta --genkey e --genuri.
if [[ "${1:-}" == "--genkey" ]]; then
  echo "1111111111111111111111111111111111111111111111111111111111111111"
  exit 0
fi
if [[ "${1:-}" == "--genuri" ]]; then
  echo "URI NWC/NCC da incollare nell'app:"
  echo "nostr+walletconnect://2222222222222222222222222222222222222222222222222222222222222222?relay=wss%3A%2F%2Frelay.example&secret=3333333333333333333333333333333333333333333333333333333333333333"
  echo ""
  echo "Client pubkey autorizzata: 4444444444444444444444444444444444444444444444444444444444444444"
  exit 0
fi
echo "fake bridge: modalità servizio non usata nei test"
exit 0
EOF
chmod +x "$WORK/artifacts/bridge-exe"

if [[ -z "${TLW_LIBPQ_DEB:-}" ]]; then
  TLW_LIBPQ_DEB="$(find /opt/cache -name 'libpq5_*.deb' | head -n 1)"
fi
export TLW_LIBPQ_DEB
[[ -n "$TLW_LIBPQ_DEB" && -f "$TLW_LIBPQ_DEB" ]] || fail "pacchetto libpq5 locale mancante (/opt/cache)"

CLN_SHA="$(sha256sum "$WORK/artifacts/cln.tar.xz" | awk '{print $1}')"
BR_SHA="$(sha256sum "$WORK/artifacts/bridge-exe" | awk '{print $1}')"
BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"

ARGS=(--skip-start --no-systemd --allow-custom-urls
  --cln-url "file://$WORK/artifacts/cln.tar.xz" --cln-sha256 "$CLN_SHA"
  --bridge-url "file://$WORK/artifacts/bridge-exe" --bridge-sha256 "$BR_SHA"
  --clnrest-port 3011 --cln-p2p-port 19735 --cln-grpc-port 19736
  --relay "wss://relay.example")

echo "== 2) dry-run =="
"$INSTALLER" --dry-run "${ARGS[@]}" >"$WORK/dry.out" 2>&1 || fail "dry-run"
grep -qi "piano di installazione" "$WORK/dry.out" || fail "dry-run: piano mancante"
pass "dry-run"

echo "== 3) fail-closed: checksum errato =="
if "$INSTALLER" "${ARGS[@]}" --cln-sha256 "$BAD_SHA" >/dev/null 2>"$WORK/fc.err"; then
  fail "checksum errato NON ha bloccato l'installazione"
fi
grep -qi "checksum" "$WORK/fc.err" || fail "messaggio di checksum mancante"
pass "fail-closed"

echo "== 4) installazione con artifact locali =="
"$INSTALLER" "${ARGS[@]}" >"$WORK/install.out" 2>&1 || { cat "$WORK/install.out"; fail "install"; }
[[ -x /root/cln-blake2b/usr/bin/lightningd ]] || fail "lightningd non installato"
[[ -f /root/cln-blake2b/usr/libexec/c-lightning/plugins/bcli ]] || fail "plugin bcli non estratto (struttura incompleta)"
[[ -f /root/.lightning/config ]] || fail "config CLN mancante"
grep -q "clnrest-port=3011" /root/.lightning/config || fail "porta clnrest custom non scritta"
grep -q "bind-addr=0.0.0.0:19735" /root/.lightning/config || fail "bind-addr p2p custom non scritto"
grep -q "grpc-port=19736" /root/.lightning/config || fail "porta grpc custom non scritta"
[[ -f /root/.lightning/bridge-rune ]] || fail "rune mancante"
[[ -f /root/bridge/config.json ]] || fail "config bridge mancante"
grep -q '"clnUrl": "http://127.0.0.1:3011"' /root/bridge/config.json \
  || fail "clnUrl del bridge non usa la porta clnrest custom (bug co-tenant)"
[[ -f /root/bridge/uri.txt ]] || fail "uri.txt mancante"
grep -q "nostr+walletconnect://2222" /root/bridge/uri.txt || fail "URI non scritta correttamente"
pass "installazione"

echo "== 5) idempotenza (config e rune NON rigenerate) =="
CFG1="$(sha256sum /root/bridge/config.json | awk '{print $1}')"
RUNE1="$(sha256sum /root/.lightning/bridge-rune | awk '{print $1}')"
touch /root/.lightning/SENTINEL
"$INSTALLER" "${ARGS[@]}" >/dev/null 2>&1 || fail "secondo run fallito"
CFG2="$(sha256sum /root/bridge/config.json | awk '{print $1}')"
RUNE2="$(sha256sum /root/.lightning/bridge-rune | awk '{print $1}')"
[[ "$CFG1" == "$CFG2" ]] || fail "config bridge sovrascritta al secondo run"
[[ "$RUNE1" == "$RUNE2" ]] || fail "rune ricreata al secondo run"
pass "idempotenza"

echo "== 6) registrazione con mock control plane =="
TOKEN="$(printf 'a%.0s' {1..64})"
python3 /opt/installer/test/docker/mock_cp.py --port 8099 --mode ok &
MOCK=$!
sleep 1
"$INSTALLER" --register --register-token "$TOKEN" --control-plane http://127.0.0.1:8099 \
  --skip-start >/dev/null 2>&1 || fail "registrazione fallita"
[[ -f /root/.tlw-node/node.json ]] || fail "node.json mancante"
grep -q '"nodeId"' /root/.tlw-node/node.json || fail "node.json senza nodeId"
kill "$MOCK" 2>/dev/null || true
wait "$MOCK" 2>/dev/null || true
pass "registrazione"

echo "== 7) token scaduto: errore chiaro, nessuno stato scritto =="
python3 /opt/installer/test/docker/mock_cp.py --port 8099 --mode expired &
MOCK=$!
sleep 1
rm -f /root/.tlw-node/node.json
if "$INSTALLER" --register --register-token "$TOKEN" --control-plane http://127.0.0.1:8099 \
  --skip-start >/dev/null 2>"$WORK/exp.err"; then
  fail "token scaduto non gestito"
fi
grep -qi "scaduto" "$WORK/exp.err" || fail "messaggio token scaduto mancante"
[[ ! -f /root/.tlw-node/node.json ]] || fail "node.json creato con token scaduto"
kill "$MOCK" 2>/dev/null || true
wait "$MOCK" 2>/dev/null || true
pass "token scaduto"

echo "== 8) uninstall: datadir INTATTO, binari rimossi =="
"$INSTALLER" --uninstall --yes >/dev/null 2>&1 || fail "uninstall fallito"
[[ -f /root/.lightning/SENTINEL ]] || fail "datadir toccato (SENTINEL mancante)"
[[ -f /root/.lightning/bridge-rune ]] || fail "rune persa con l'uninstall"
[[ ! -d /root/cln-blake2b ]] || fail "cln-home non rimosso"
[[ ! -d /root/bridge ]] || fail "bridge-dir non rimosso"
pass "uninstall"

echo ""
echo "================= TUTTI I TEST OK ================="
