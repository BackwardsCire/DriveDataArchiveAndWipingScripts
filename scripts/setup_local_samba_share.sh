#! /usr/bin/env bash
# setup_local_samba_share.sh - create a local SMB/CIFS share for archive output.
#
# This is for the "no NAS" case: archive_media.sh writes recovered files to a
# local directory, and Samba publishes that directory to other machines on the
# LAN.
#
# Usage:
#   sudo ./scripts/setup_local_samba_share.sh
#
# Optional environment overrides:
#   SHARE_PATH=/srv/legacy-media
#   SHARE_NAME=legacy-media
#   SHARE_GROUP=legacymedia
#   SHARE_USER=$SUDO_USER
#   INSTALL_PACKAGES=1
#   OPEN_FIREWALL=ask        # ask | 1 | 0
#   SKIP_SMBPASSWD=0

set -Eeuo pipefail

SHARE_PATH="${SHARE_PATH:-/srv/legacy-media}"
SHARE_NAME="${SHARE_NAME:-legacy-media}"
SHARE_GROUP="${SHARE_GROUP:-legacymedia}"
SHARE_USER="${SHARE_USER:-${SUDO_USER:-}}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
OPEN_FIREWALL="${OPEN_FIREWALL:-ask}"
SKIP_SMBPASSWD="${SKIP_SMBPASSWD:-0}"

SMB_CONF="/etc/samba/smb.conf"
BEGIN_MARK="# BEGIN disktools local archive share"
END_MARK="# END disktools local archive share"

log() { printf '==> %s\n' "$*"; }
fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [[ $EUID -ne 0 ]]; then
  fatal "Run as root: sudo $0"
fi

if [[ -z "$SHARE_USER" || "$SHARE_USER" == "root" ]]; then
  fatal "Set SHARE_USER to the normal Linux account that should own the share."
fi

if ! getent passwd "$SHARE_USER" >/dev/null; then
  fatal "No such local user: $SHARE_USER"
fi

if [[ "$SHARE_NAME" =~ [/\[]|\] ]]; then
  fatal "SHARE_NAME must not contain '/', '[' or ']'."
fi

if [[ "$INSTALL_PACKAGES" == "1" ]]; then
  have apt-get || fatal "apt-get not found; install Samba packages manually for this OS."
  log "Installing Samba packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y samba smbclient cifs-utils acl
fi

for cmd in testparm smbpasswd pdbedit systemctl; do
  have "$cmd" || fatal "Missing command '$cmd'. Install the samba package first."
done

log "Preparing $SHARE_PATH"
groupadd -f "$SHARE_GROUP"
usermod -aG "$SHARE_GROUP" "$SHARE_USER"
mkdir -p "$SHARE_PATH"
chown "$SHARE_USER:$SHARE_GROUP" "$SHARE_PATH"
chmod 2775 "$SHARE_PATH"

if [[ "$SKIP_SMBPASSWD" != "1" ]]; then
  # `pdbedit -L -u USER` returns 0 with empty stdout on some samba versions
  # when the user is absent, so check for actual output rather than rc.
  if pdbedit -L -u "$SHARE_USER" 2>/dev/null | grep -q .; then
    log "Samba user already exists: $SHARE_USER"
  else
    log "Creating Samba password for $SHARE_USER"
    echo "Enter the password this user should use when connecting to \\\\$(hostname)\\${SHARE_NAME}:"
    smbpasswd -a "$SHARE_USER"
  fi
fi

[[ -f "$SMB_CONF" ]] || fatal "Missing $SMB_CONF"
backup="${SMB_CONF}.disktools.$(date -u +'%Y%m%dT%H%M%SZ').bak"
cp -a "$SMB_CONF" "$backup"
log "Backed up Samba config to $backup"

tmp="$(mktemp)"
trap '[[ -n "${tmp:-}" && -f "$tmp" ]] && rm -f "$tmp"' EXIT
awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
  $0 == begin {skip=1; next}
  $0 == end {skip=0; next}
  skip != 1 {print}
' "$SMB_CONF" > "$tmp"

cat >> "$tmp" <<EOF

$BEGIN_MARK
[$SHARE_NAME]
   comment = Disktools recovered media archive
   path = $SHARE_PATH
   browseable = yes
   read only = no
   guest ok = no
   valid users = @$SHARE_GROUP
   force group = $SHARE_GROUP
   create mask = 0664
   directory mask = 2775
$END_MARK
EOF

log "Validating Samba config"
testparm -s "$tmp" >/dev/null

install -m 0644 "$tmp" "$SMB_CONF"
rm -f "$tmp"
trap - EXIT

log "Starting Samba services"
systemctl enable --now smbd
if systemctl list-unit-files nmbd.service >/dev/null 2>&1; then
  systemctl enable --now nmbd || true
fi
systemctl reload smbd || systemctl restart smbd

if have ufw && ufw status | grep -q '^Status: active'; then
  case "$OPEN_FIREWALL" in
    1|yes|true)
      log "Opening Samba in ufw"
      ufw allow Samba
      ;;
    ask)
      read -rp "ufw is active. Allow Samba through the firewall now? [y/N]: " reply
      if [[ "${reply:-N}" =~ ^[Yy]$ ]]; then
        ufw allow Samba
      fi
      ;;
    *) log "ufw is active; leaving firewall unchanged." ;;
  esac
fi

cat <<EOF

Local SMB/CIFS share is configured.

Connect from another machine:
  smb://$(hostname)/$SHARE_NAME
  \\\\$(hostname)\\$SHARE_NAME

Use this archive config for local-only output:
  NAS_TRANSPORT="none"
  NAS_DEST="$SHARE_PATH"

Note: $SHARE_USER was added to group '$SHARE_GROUP'. Log out and back in if
you want that group membership reflected in new shells without sudo.
EOF
