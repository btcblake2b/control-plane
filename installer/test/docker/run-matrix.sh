#!/usr/bin/env bash
# Matrice di test dell'installer (richiede Docker). Da eseguire dalla cartella installer/.
# Nota: su Windows/Docker Desktop usare i due comandi docker build/run equivalenti.
set -euo pipefail
cd "$(dirname "$0")/../.."

for distro in ubuntu2404 ubuntu2204; do
  echo "═══════════════ $distro ═══════════════"
  docker build -f "test/docker/Dockerfile.$distro" -t "tlw-installer-test:$distro" .
  docker run --rm "tlw-installer-test:$distro"
done

echo "═══════════════ MATRICE COMPLETATA ═══════════════"
