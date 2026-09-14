#!/usr/bin/env bash
# Crea il pacchetto di installazione della release:
#   dist/tlw-node-installer-<VER>.tar.gz  (+ .sha256)
#
# PERCHÉ richiede l'albero pulito: il pacchetto deve corrispondere ESATTAMENTE
# a un commit (riproducibilità); la versione è letta da install.sh.
#
# Uso: bash scripts/package-installer.sh [--out DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="$2"
      shift 2
      ;;
    *)
      echo "uso: $0 [--out DIR]" >&2
      exit 2
      ;;
  esac
done

command -v tar >/dev/null || { echo "FAIL: tar mancante" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "FAIL: sha256sum mancante" >&2; exit 1; }

VER="$(sed -n 's/^INSTALLER_VERSION="\(.*\)"$/\1/p' "$ROOT/installer/install.sh")"
[[ -n "$VER" ]] || { echo "FAIL: INSTALLER_VERSION non trovato in install.sh" >&2; exit 1; }

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "FAIL: working tree non pulito (committa prima di impacchettare)" >&2
  exit 1
fi

# Release readiness: senza pin bridge attivo il pacchetto NON è pubblicabile.
grep -Eq '^BRIDGE_SHA256_DEFAULT="[0-9a-f]{64}"$' "$ROOT/installer/install.sh" \
  || { echo "FAIL: pin bridge non attivo (BRIDGE_SHA256_DEFAULT)" >&2; exit 1; }

NAME="tlw-node-installer-$VER"
STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE/lib" "$OUT"

cp "$ROOT/installer/install.sh" "$STAGE/install.sh"
cp "$ROOT/installer/lib/"*.sh "$STAGE/lib/"
# Il README del pacchetto usa un segnaposto di versione (evita drift).
sed "s/{{VERSION}}/$VER/g" "$ROOT/installer/README.md" >"$STAGE/README.md"
chmod 755 "$STAGE/install.sh"

tar -C "$(dirname "$STAGE")" -czf "$OUT/$NAME.tar.gz" "$NAME"
( cd "$OUT" && sha256sum "$NAME.tar.gz" >"$NAME.tar.gz.sha256" )

echo "OK: $OUT/$NAME.tar.gz"
cat "$OUT/$NAME.tar.gz.sha256"
