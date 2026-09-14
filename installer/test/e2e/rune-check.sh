#!/usr/bin/env bash
# Diagnostica "RESTRICTED" del bridge: verifica che la rune del nodo autorizzi
# il metodo via clnrest sulla porta attesa, e mostra cosa risponde la 3001
# (per distinguere "rune invalida" da "bridge che parla con il nodo sbagliato").
#
# Uso: bash rune-check.sh [CLNREST_PORT]   (default 3011, il nodo di test)
set -euo pipefail
cd "$HOME/e2e-test"
PORT="${1:-3011}"
RUNE_FILE="lightning/bridge-rune"

echo "== file rune =="
echo "byte: $(wc -c <"$RUNE_FILE"), righe: $(wc -l <"$RUNE_FILE")"
head -c 16 "$RUNE_FILE"; echo "  <-- atteso: LIGHTNING_RUNE="

RUNE="$(sed -n 's/^LIGHTNING_RUNE="\(.*\)"$/\1/p' "$RUNE_FILE")"
echo "rune estratta: ${#RUNE} char"

echo
echo "== rune contro clnrest =="
for p in 3001 "$PORT"; do
  printf 'porta %s -> ' "$p"
  curl -s -o /tmp/rune-check-out.txt -w "%{http_code}" \
    -X POST -H "rune: $RUNE" -H "Content-Type: application/json" \
    -d '{}' "http://127.0.0.1:$p/v1/listfunds" || true
  echo
  head -c 180 /tmp/rune-check-out.txt; echo
done

echo
echo "== clnUrl nella config del bridge di test (atteso porta $PORT) =="
grep clnUrl bridge/config.json
