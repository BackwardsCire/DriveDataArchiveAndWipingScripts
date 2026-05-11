#! /usr/bin/env bash
# configure_archive_destination.sh - toggle archive.conf between local/NAS modes.
#
# Usage:
#   ./scripts/configure_archive_destination.sh local [path]
#   ./scripts/configure_archive_destination.sh mounted <dest-path>
#   ./scripts/configure_archive_destination.sh cifs <//server/share> <mountpoint> <dest-path> <credentials-file>
#   ./scripts/configure_archive_destination.sh nfs <server:/export> <mountpoint> <dest-path>
#
# Defaults:
#   local path: /srv/legacy-media

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJ_DIR="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
CONFIG_FILE="${CONFIG:-${PROJ_DIR}/config/archive.conf}"
CONFIG_EXAMPLE="${PROJ_DIR}/config/archive.conf.example"

usage() {
  sed -n '2,13p' "$0"
}

ensure_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
    echo "Created $CONFIG_FILE from example."
  fi
}

set_key() {
  local key="$1" value="$2" escaped
  escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  if grep -qE "^${key}=" "$CONFIG_FILE"; then
    sed -i -E "s|^${key}=.*|${key}=\"${escaped}\"|" "$CONFIG_FILE"
  else
    printf '%s="%s"\n' "$key" "$escaped" >> "$CONFIG_FILE"
  fi
}

mode="${1:-}"
if [[ -z "$mode" || "$mode" == "-h" || "$mode" == "--help" || "$mode" == "help" ]]; then
  usage
  exit 0
fi
shift

ensure_config

case "$mode" in
  local|none)
    dest="${1:-/srv/legacy-media}"
    set_key NAS_TRANSPORT none
    set_key NAS_DEST "$dest"
    echo "Archive destination set to local mode: $dest"
    ;;
  mounted)
    [[ $# -eq 1 ]] || { usage >&2; exit 1; }
    set_key NAS_TRANSPORT mounted
    set_key NAS_DEST "$1"
    echo "Archive destination set to already-mounted NAS path: $1"
    ;;
  cifs)
    [[ $# -eq 4 ]] || { usage >&2; exit 1; }
    set_key NAS_TRANSPORT cifs
    set_key NAS_CIFS_SHARE "$1"
    set_key NAS_CIFS_MOUNTPOINT "$2"
    set_key NAS_DEST "$3"
    set_key NAS_CIFS_CREDENTIALS "$4"
    echo "Archive destination set to CIFS share $1 -> $3"
    ;;
  nfs)
    [[ $# -eq 3 ]] || { usage >&2; exit 1; }
    set_key NAS_TRANSPORT nfs
    set_key NAS_NFS_EXPORT "$1"
    set_key NAS_NFS_MOUNTPOINT "$2"
    set_key NAS_DEST "$3"
    echo "Archive destination set to NFS export $1 -> $3"
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    usage >&2
    exit 1
    ;;
esac

echo "Config: $CONFIG_FILE"
case "$mode" in
  local|none|mounted)
    grep -E '^(NAS_TRANSPORT|NAS_DEST)=' "$CONFIG_FILE" || true
    ;;
  cifs)
    grep -E '^(NAS_TRANSPORT|NAS_DEST|NAS_CIFS_SHARE|NAS_CIFS_MOUNTPOINT|NAS_CIFS_CREDENTIALS)=' "$CONFIG_FILE" || true
    ;;
  nfs)
    grep -E '^(NAS_TRANSPORT|NAS_DEST|NAS_NFS_EXPORT|NAS_NFS_MOUNTPOINT)=' "$CONFIG_FILE" || true
    ;;
esac
