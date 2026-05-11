#! /usr/bin/env bash
# disktools.sh — single entry point for the archive + rescue + wipe workflows.
#
#   ./disktools.sh                 # interactive menu
#   ./disktools.sh detect          # straight to detect_media.sh
#   ./disktools.sh archive [dev]   # straight to archive_media.sh
#   ./disktools.sh rescue          # straight to interactive_data_rescue.sh
#   ./disktools.sh wipe <dev>      # straight to wipedriveforsale.sh
#   ./disktools.sh setup-share     # configure a local Samba/SMB share
#   ./disktools.sh dest local      # set archive destination mode
#   ./disktools.sh status          # list recent ~/drive_reports entries
#
# The detect path runs without sudo. The archive/rescue/wipe paths need
# sudo for ddrescue/mount/nwipe; the dispatcher tells you so but does not
# re-invoke itself under sudo (that interacts badly with tmux and with the
# config-file paths under your home directory).

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SCRIPTS="${SCRIPT_DIR}/scripts"

OWNER="${SUDO_USER:-$USER}"
OWNER_HOME="$(getent passwd "${OWNER}" | cut -d: -f6)"
[[ -z "$OWNER_HOME" ]] && OWNER_HOME="$HOME"
REPORTS="${OWNER_HOME}/drive_reports"

bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
note()   { printf '   %s\n' "$*"; }

show_help() {
  cat <<'EOF'
disktools.sh — single entry point for archive, rescue, wipe, and setup tasks.

Usage:
  ./disktools.sh                 Interactive menu
  ./disktools.sh detect          Read-only media scan
  sudo ./disktools.sh archive [dev]
  sudo ./disktools.sh rescue
  sudo ./disktools.sh wipe <dev>
  sudo ./disktools.sh setup-share
  ./disktools.sh dest local [/srv/legacy-media]
  ./disktools.sh dest mounted /mnt/nas/legacy-media
  ./disktools.sh dest cifs //nas/share /mnt/nas /mnt/nas/legacy-media /root/.smbcredentials-nas
  ./disktools.sh dest nfs nas:/export /mnt/nas /mnt/nas/legacy-media
  ./disktools.sh status
EOF
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo
    case "${1:-}" in
      setup-share)
        echo "This action installs packages and edits Samba system config, so it needs root."
        ;;
      *)
        echo "This action writes to block devices or mounts filesystems and needs root."
        ;;
    esac
    echo "Re-run from a root shell, e.g.:"
    echo "    sudo tmux new -s disktools '${BASH_SOURCE[0]} $*'"
    echo
    exit 1
  fi
}

show_menu() {
  clear 2>/dev/null || true
  cat <<EOF
$(bold "Drive Data Archive & Wiping Toolkit")
$(bold "===================================")

  1) Detect attached media          (read-only scan, no sudo needed)
  2) Archive media to NAS           (ddrescue + multi-pass + rsync)
  3) Rescue from a specific device  (older interactive helper, HFS-aware)
  4) Wipe a drive for resale        (DESTRUCTIVE — irreversible)
  5) Show recent session reports
  6) Set up local SMB/CIFS share    (no NAS; share copied media from this box)
  7) Configure archive destination  (local/NAS mode)
  q) Quit

EOF
  note "Reports: $REPORTS"
  note "Tip: long imaging runs survive disconnects under tmux."
  echo
  read -rp "Choice: " choice
  case "$choice" in
    1) exec "$SCRIPTS/detect_media.sh" ;;
    2)
      need_root archive
      echo
      read -rp "Device to archive (blank to pick from a detection scan): " dev
      if [[ -n "$dev" ]]; then
        exec "$SCRIPTS/archive_media.sh" "$dev"
      else
        exec "$SCRIPTS/archive_media.sh"
      fi
      ;;
    3)
      need_root rescue
      exec "$SCRIPTS/interactive_data_rescue.sh"
      ;;
    4)
      need_root wipe
      echo
      echo "$(bold 'WIPE — this is destructive and irreversible.')"
      echo "Type 'wipe' (lowercase) to continue, anything else to cancel."
      read -rp "Confirm: " c
      [[ "$c" == "wipe" ]] || { echo "Cancelled."; exit 1; }
      read -rp "Target device path (e.g. /dev/sdb): " dev
      [[ -b "$dev" ]] || { echo "Not a block device: $dev"; exit 1; }
      exec "$SCRIPTS/wipedriveforsale.sh" "$dev"
      ;;
    5) status_summary ;;
    6)
      need_root setup-share
      exec "$SCRIPTS/setup_local_samba_share.sh"
      ;;
    7)
      echo
      echo "Destination modes:"
      echo "  local   -> /srv/legacy-media on this host"
      echo "  mounted -> already-mounted NAS path"
      echo "  cifs    -> SMB/CIFS NAS share"
      echo "  nfs     -> NFS export"
      read -rp "Mode [local/mounted/cifs/nfs]: " mode
      case "$mode" in
        local|"")
          read -rp "Local destination [/srv/legacy-media]: " dest
          exec "$SCRIPTS/configure_archive_destination.sh" local "${dest:-/srv/legacy-media}"
          ;;
        mounted)
          read -rp "Mounted NAS destination path: " dest
          exec "$SCRIPTS/configure_archive_destination.sh" mounted "$dest"
          ;;
        cifs)
          read -rp "CIFS share (//server/share): " share
          read -rp "Mountpoint [/mnt/nas]: " mnt
          read -rp "Destination path under mountpoint: " dest
          read -rp "Credentials file [/root/.smbcredentials-nas]: " creds
          exec "$SCRIPTS/configure_archive_destination.sh" cifs "$share" "${mnt:-/mnt/nas}" "$dest" "${creds:-/root/.smbcredentials-nas}"
          ;;
        nfs)
          read -rp "NFS export (server:/export): " export
          read -rp "Mountpoint [/mnt/nas]: " mnt
          read -rp "Destination path under mountpoint: " dest
          exec "$SCRIPTS/configure_archive_destination.sh" nfs "$export" "${mnt:-/mnt/nas}" "$dest"
          ;;
        *) echo "Unknown mode: $mode"; exit 1 ;;
      esac
      ;;
    q|Q|"") echo "Bye."; exit 0 ;;
    *) echo "Unknown choice: $choice"; exit 1 ;;
  esac
}

status_summary() {
  if [[ ! -d "$REPORTS" ]]; then
    echo "No reports directory yet: $REPORTS"
    exit 0
  fi
  echo "Recent entries in $REPORTS:"
  ls -1tr "$REPORTS" 2>/dev/null | tail -30 | sed 's/^/  /'
  echo
  echo "(Run ./disktools.sh again to start another action.)"
}

case "${1:-menu}" in
  menu|"")     show_menu ;;
  detect|d)    shift; exec "$SCRIPTS/detect_media.sh" "$@" ;;
  archive|a)   shift; need_root archive; exec "$SCRIPTS/archive_media.sh" "$@" ;;
  rescue|r)    shift; need_root rescue;  exec "$SCRIPTS/interactive_data_rescue.sh" "$@" ;;
  wipe|w)
    shift
    need_root wipe
    [[ $# -ge 1 ]] || { echo "Usage: $0 wipe /dev/sdX"; exit 1; }
    exec "$SCRIPTS/wipedriveforsale.sh" "$@"
    ;;
  setup-share|share|samba)
    shift
    need_root setup-share
    exec "$SCRIPTS/setup_local_samba_share.sh" "$@"
    ;;
  dest|destination|config-dest)
    shift
    exec "$SCRIPTS/configure_archive_destination.sh" "$@"
    ;;
  status|s)    status_summary ;;
  -h|--help|help)
    show_help
    ;;
  *)
    echo "Unknown subcommand: $1"
    echo "Run '$0' with no args for the menu, or '$0 --help'."
    exit 1
    ;;
esac
