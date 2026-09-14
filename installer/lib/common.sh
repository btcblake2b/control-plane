#!/usr/bin/env bash
# Libreria comune dell'installer TLW Node.
# Convenzioni: set -euo pipefail nel chiamante; MAI segreti nei log.

# Percorsi (override via env, usati anche dai test)
CLN_HOME="${TLW_CLN_HOME:-$HOME/cln-blake2b}"
LIGHTNING_DIR="${TLW_LIGHTNING_DIR:-$HOME/.lightning}"
BRIDGE_DIR="${TLW_BRIDGE_DIR:-$HOME/bridge}"
NODE_STATE_DIR="${TLW_NODE_STATE_DIR:-$HOME/.tlw-node}"
LOG_FILE="${TLW_LOG_FILE:-$HOME/tlw-node-install.log}"

# Stato runtime (valorizzati in install.sh)
DRY_RUN="${DRY_RUN:-0}"
SKIP_START="${SKIP_START:-0}"

log() {
  # PERCHÉ: log su file per diagnosi + stdout per l'utente.
  # Qui passano SOLO messaggi tecnici: mai token, secret, rune o chiavi.
  local ts
  ts="$(date -u +%FT%TZ)"
  printf '%s [tlw-install] %s\n' "$ts" "$*" | tee -a "$LOG_FILE" >&2
}

warn() {
  local ts
  ts="$(date -u +%FT%TZ)"
  printf '%s [tlw-install] WARN: %s\n' "$ts" "$*" | tee -a "$LOG_FILE" >&2
}

die() {
  local ts
  ts="$(date -u +%FT%TZ)"
  printf '%s [tlw-install] ERRORE: %s\n' "$ts" "$*" | tee -a "$LOG_FILE" >&2
  exit 1
}

init_log_file() {
  : >>"$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "comando richiesto non trovato: $1"
}

require_hex64() {
  # $1 = valore, $2 = nome campo (per il messaggio)
  [[ "$1" =~ ^[0-9a-f]{64}$ ]] || die "$2 non valido (atteso hex 64 lowercase)"
}

# Scarica con verifica fail-closed del checksum.
# Uso: download_verified URL SHA256_ATTESO DESTINAZIONE
download_verified() {
  local url="$1" expected="$2" dest="$3"
  [[ -n "$expected" ]] || die "checksum mancante per $url (fail-closed: nessun download senza verifica)"
  case "$url" in
    file://*)
      # PERCHÉ: usato dai container di test con artifact locali (mai in produzione).
      cp "${url#file://}" "$dest" || die "copia fallita: $url"
      ;;
    *)
      local tmp="${dest}.part"
      curl --fail --location --silent --show-error --output "$tmp" "$url" \
        || die "download fallito: $url"
      mv "$tmp" "$dest"
      ;;
  esac
  local actual
  actual="$(sha256sum "$dest" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$dest"
    die "checksum NON corrispondente per $url (atteso $expected, ottenuto $actual) — installazione annullata"
  fi
}

# True se il valore (case-insensitive) vale 1/true/yes.
is_true() {
  case "${1,,}" in
    1|true|yes) return 0 ;;
    *) return 1 ;;
  esac
}
