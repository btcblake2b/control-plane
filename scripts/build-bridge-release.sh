#!/usr/bin/env bash
# Build del bridge AOT linux-amd64 per la RELEASE, dal sorgente del repo.
#
# PERCHÉ su Linux: `dart compile exe` non fa cross-compile — il binario Linux
# si costruisce su Linux. Sorgente: cartella bridge/ del repo control-plane
# (snapshot di release) — chiunque può ricostruire questa build.
# NOTA: il bridge è sviluppato nel repo wallet; il tag pubblico wallet v0.1.1
# NON include bridge/, quindi per la release il sorgente è incluso qui.
#
# Uso: BRIDGE_SRC=/path/bridge bash build-bridge-release.sh   (sul server Linux)
# Output: $OUT/bridge-exe-linux-amd64 + .sha256 (strumenti di release)
set -euo pipefail

OUT="${OUT:-$HOME/bridge-build}"
SRC="${BRIDGE_SRC:-$HOME/bridge-build/bridge}"
DART="$HOME/dart-sdk/dart-sdk/bin/dart"
SDK_ZIP="$HOME/dart-sdk.zip"

echo "== 1. Dart SDK (user-level) =="
if [[ ! -x "$DART" ]]; then
  curl -fsSL -o "$SDK_ZIP" \
    https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-x64-release.zip
  mkdir -p "$HOME/dart-sdk"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$SDK_ZIP" -d "$HOME/dart-sdk"
  else
    python3 -c "import zipfile,os; zipfile.ZipFile(os.path.expanduser('~/dart-sdk.zip')).extractall(os.path.expanduser('~/dart-sdk'))"
  fi
fi
"$DART" --version

echo "== 2. sorgente bridge =="
mkdir -p "$OUT"
[[ -f "$SRC/bin/bridge.dart" ]] || { echo "FAIL: sorgente bridge non trovato in $SRC (usa BRIDGE_SRC=...)"; exit 1; }
echo "sorgente: $SRC"

echo "== 3. pub get =="
cd "$SRC"
"$DART" pub get

echo "== 4. test del sorgente (prima della build) =="
"$DART" test 2>&1 | tail -n 3

echo "== 5. compile AOT =="
"$DART" compile exe bin/bridge.dart -o "$OUT/bridge-exe-linux-amd64"

echo "== 6. sha256 =="
sha256sum "$OUT/bridge-exe-linux-amd64" | tee "$OUT/bridge-exe-linux-amd64.sha256"

echo "== 7. smoke: --genkey =="
"$OUT/bridge-exe-linux-amd64" --genkey | cut -c1-8
echo "  (primi 8 di 64 hex attesi)"

echo
echo "RELEASE-BUILD OK: $OUT/bridge-exe-linux-amd64"
