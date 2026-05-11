#! /usr/bin/env bash
# archive_media.sh — archiver for Zip/CD/DVD/legacy HDD to local/NAS storage.
#
# Workflow:
#   1. Load config/archive.conf (copy from .example if not present).
#   2. Verify archive destination is mounted/reachable.
#   3. Detect candidate source media via detect_media.sh; let operator pick
#      (or accept device path on the command line).
#   4. ddrescue in stages: fast → retry → optional deep-scrape.
#   5. Optional fallback tools (dvdisaster, safecopy) if bad sectors remain.
#   6. Mount the image read-only and rsync the contents to the archive destination.
#   7. Write a per-case report locally and into the archive case directory.
#
# Run under tmux. Run with sudo (ddrescue + mount need it).
#
# Env toggles:
#   DRY_RUN=1        Skip every destructive/expensive command but exercise the flow.
#   AUTO=1           No interactive prompts; use defaults from config (best-effort).
#   CONFIG=/path     Override config file path.

set -Eeuo pipefail
umask 077

# Block devices and mount(8) need root. Bail early with a clear message rather
# than failing deep in ddrescue. disktools.sh's `need_root` already covers the
# menu path; this catches direct invocation of the script.
if [[ $EUID -ne 0 ]]; then
  echo "Error: run as root (sudo $0 [device])" >&2
  exit 1
fi

# ---------- paths & config -------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJ_DIR="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  OWNER="$SUDO_USER"
else
  OWNER="$(stat -c '%U' "$PROJ_DIR" 2>/dev/null || echo "${USER}")"
  [[ -z "$OWNER" || "$OWNER" == "UNKNOWN" ]] && OWNER="${USER}"
fi
OWNER_HOME="$(getent passwd "${OWNER}" | cut -d: -f6)"
[[ -z "$OWNER_HOME" ]] && OWNER_HOME="$(eval echo "~${OWNER}")"

CONFIG_FILE="${CONFIG:-${PROJ_DIR}/config/archive.conf}"
CONFIG_EXAMPLE="${PROJ_DIR}/config/archive.conf.example"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "No config at: $CONFIG_FILE"
  echo "Copy ${CONFIG_EXAMPLE} to ${CONFIG_FILE}, choose local/NAS destination settings, and rerun."
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Validate that the config didn't leave us with empty/unset paths. mkdir -p ""
# silently no-ops, which would later look like a permission error. Done before
# the tilde-expansion below so a config that simply omits a key reports a
# friendly error rather than a `set -u` unbound-variable trace.
for v in NAS_DEST SCRATCH_DIR REPORT_ROOT NAS_TRANSPORT; do
  if [[ -z "${!v:-}" ]]; then
    echo "Config error: $v is empty or unset in $CONFIG_FILE" >&2
    exit 1
  fi
done

# expand ~/ in config-supplied paths
SCRATCH_DIR="${SCRATCH_DIR/#\~/$OWNER_HOME}"
REPORT_ROOT="${REPORT_ROOT/#\~/$OWNER_HOME}"

DRY_RUN="${DRY_RUN:-0}"
AUTO="${AUTO:-0}"

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
SESSION_LOG="${REPORT_ROOT}/archive_${TS}.log"

mkdir -p "$REPORT_ROOT" "$SCRATCH_DIR"
chown -R "${OWNER}:${OWNER}" "$REPORT_ROOT" "$SCRATCH_DIR" 2>/dev/null || true

exec > >(tee -a "$SESSION_LOG") 2>&1

# ---------- helpers --------------------------------------------------------
log()    { printf '==> %s\n' "$*"; }
warn()   { printf '!! %s\n' "$*" >&2; }
fatal()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
phase()  { printf '\n===== %s :: %s =====\n' "$(date -u +'%FT%TZ')" "$*"; }
pause()  { [[ "$AUTO" == "1" ]] && return 0; read -rp "==> $* (Enter to continue, Ctrl-C to abort) "; }
confirm() {
  local msg="$1" default="${2:-N}" reply
  if [[ "$AUTO" == "1" ]]; then [[ "$default" =~ ^[Yy]$ ]]; return; fi
  read -rp "==> ${msg} [y/N]: " reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}
require() { command -v "$1" >/dev/null 2>&1 || fatal "Missing tool: $1 (install per INSTALL.md)"; }
fix_owner() { chown -R "${OWNER}:${OWNER}" "$1" 2>/dev/null || true; }

require ddrescue
require ddrescuelog
require timeout
require lsblk
require parted
require findmnt
require rsync
require file
require mount
require umount
require blkid

# Optional tools — checked before use, not at startup.
have() { command -v "$1" >/dev/null 2>&1; }
require_config() {
  local v="$1"
  [[ -n "${!v:-}" ]] || fatal "Config error: $v is required when NAS_TRANSPORT=${NAS_TRANSPORT}."
}

sanitize_case_name() {
  local s="${1:-}"
  s="${s,,}"
  s="${s//[^a-z0-9._-]/-}"
  s="$(sed -E 's/-+/-/g; s/^[.-]+//; s/[.-]+$//' <<<"$s")"
  printf '%s' "${s:0:60}"
}

suggest_case_name() {
  local dev="$1" mtype="$2" label=""

  label="$(blkid -o value -s LABEL "$dev" 2>/dev/null | head -n1 || true)"
  if [[ -z "$label" ]]; then
    label="$(udevadm info --query=property --name="$dev" 2>/dev/null \
      | awk -F= '$1=="ID_FS_LABEL"{print $2; exit}')"
  fi
  if [[ -z "$label" && ( "$mtype" == "cd" || "$mtype" == "dvd" || "$mtype" == "optical" ) ]] && have isoinfo; then
    label="$(isoinfo -d -i "$dev" 2>/dev/null \
      | awk -F: '/Volume id:/ {sub(/^[ \t]+/, "", $2); print $2; exit}')"
  fi

  sanitize_case_name "${label:-}"
}

existing_parent() {
  local path="$1"
  while [[ ! -e "$path" && "$path" != "/" ]]; do
    path="$(dirname "$path")"
  done
  printf '%s' "$path"
}

# ---------- archive destination reachability -------------------------------
ensure_nas_mounted() {
  case "${NAS_TRANSPORT:-none}" in
    none)
      log "NAS_TRANSPORT=none — using local path: $NAS_DEST"
      mkdir -p "$NAS_DEST"
      chown "$OWNER" "$NAS_DEST" 2>/dev/null || true
      chmod u+rwx "$NAS_DEST" 2>/dev/null || true
      ;;
    mounted)
      local parent_path parent
      parent_path="$(existing_parent "$NAS_DEST")"
      parent="$(findmnt -no TARGET --target "$parent_path" 2>/dev/null || true)"
      [[ -z "$parent" || "$parent" == "/" ]] && fatal "NAS_DEST ($NAS_DEST) is not under a mounted NAS filesystem. Mount it first, or use NAS_TRANSPORT=none for local storage."
      log "NAS already mounted at: $parent"
      mkdir -p "$NAS_DEST"
      ;;
    cifs)
      require_config NAS_CIFS_SHARE
      require_config NAS_CIFS_MOUNTPOINT
      require_config NAS_CIFS_CREDENTIALS
      require_config NAS_CIFS_OPTS
      have mount.cifs || fatal "Missing mount.cifs (install cifs-utils)."
      [[ -r "$NAS_CIFS_CREDENTIALS" ]] || fatal "CIFS credentials file is not readable: $NAS_CIFS_CREDENTIALS"
      mkdir -p "$NAS_CIFS_MOUNTPOINT"
      if mountpoint -q "$NAS_CIFS_MOUNTPOINT"; then
        log "CIFS already mounted at $NAS_CIFS_MOUNTPOINT"
      else
        log "Mounting CIFS share $NAS_CIFS_SHARE -> $NAS_CIFS_MOUNTPOINT"
        mount -t cifs "$NAS_CIFS_SHARE" "$NAS_CIFS_MOUNTPOINT" \
          -o "credentials=${NAS_CIFS_CREDENTIALS},${NAS_CIFS_OPTS}"
      fi
      mkdir -p "$NAS_DEST"
      ;;
    nfs)
      require_config NAS_NFS_EXPORT
      require_config NAS_NFS_MOUNTPOINT
      require_config NAS_NFS_OPTS
      have mount.nfs || fatal "Missing mount.nfs (install nfs-common)."
      mkdir -p "$NAS_NFS_MOUNTPOINT"
      if mountpoint -q "$NAS_NFS_MOUNTPOINT"; then
        log "NFS already mounted at $NAS_NFS_MOUNTPOINT"
      else
        log "Mounting NFS export $NAS_NFS_EXPORT -> $NAS_NFS_MOUNTPOINT"
        mount -t nfs "$NAS_NFS_EXPORT" "$NAS_NFS_MOUNTPOINT" -o "$NAS_NFS_OPTS"
      fi
      mkdir -p "$NAS_DEST"
      ;;
    *) fatal "Unknown NAS_TRANSPORT: $NAS_TRANSPORT" ;;
  esac
  # Writability probe
  local probe="${NAS_DEST}/.archive_write_test_${TS}"
  : > "$probe" 2>/dev/null || fatal "Archive destination ${NAS_DEST} is not writable."
  rm -f "$probe"
}

# ---------- pick a device --------------------------------------------------
pick_device() {
  local supplied="${1:-}"
  if [[ -n "$supplied" ]]; then
    [[ -b "$supplied" ]] || fatal "Not a block device: $supplied"
    SRC="$supplied"
    return
  fi
  log "Scanning for source media..."
  bash "${SCRIPT_DIR}/detect_media.sh"
  echo
  if [[ "$AUTO" == "1" ]]; then
    fatal "AUTO=1 with no device specified — pass a device path on the command line."
  fi
  read -rp "Enter the SOURCE device path (e.g. /dev/sr0, /dev/sdc): " SRC
  [[ -b "$SRC" ]] || fatal "Not a block device: $SRC"
}

# ---------- safety ---------------------------------------------------------
guard_device() {
  local dev="$1"
  local root_src parent target
  root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  parent="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1 || true)"
  target="$(basename "$dev")"
  [[ "$target" == "$parent" ]] && fatal "$dev is the SYSTEM DISK. Refusing."
  if lsblk -ln -o NAME,MOUNTPOINT "$dev" 2>/dev/null | awk '$2!=""{exit 0} END{exit 1}'; then
    warn "$dev or a partition is currently mounted:"
    lsblk -ln -o NAME,MOUNTPOINT "$dev" | awk '$2!=""{print "  /dev/"$1" -> "$2}'
    confirm "Unmount it now?" Y || fatal "Aborted by user."
    while read -r p; do umount -v "/dev/$p" || true; done < <(lsblk -ln -o NAME,MOUNTPOINT "$dev" | awk '$2!=""{print $1}')
  fi
}

guard_media_present() {
  local dev="$1" mtype="$2" size_bytes short sectors
  size_bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"

  if [[ "$mtype" == "cd" || "$mtype" == "dvd" || "$mtype" == "optical" ]]; then
    short="${dev##*/}"
    sectors="$(cat "/sys/block/${short}/size" 2>/dev/null || echo 0)"
    if [[ "$sectors" == "0" || "$size_bytes" == "0" ]]; then
      fatal "$dev reports 0 bytes / no optical medium. Eject and reinsert the disc, wait for spin-up, then run './disktools.sh detect' until FS/STATE is not 'no medium'."
    fi
  elif [[ "$size_bytes" == "0" ]]; then
    fatal "$dev reports 0 bytes. Refusing to image an empty/no-media device."
  fi
}

# ---------- imaging --------------------------------------------------------
# Globals set by image_source: IMAGE, MAPFILE, BSARG, MTYPE, BAD_BYTES, IMAGING_RC, DEEP_RC
map_metric_bytes() {
  local map="$1" label="$2"
  [[ -s "$map" ]] || { echo 0; return; }
  ddrescuelog -t "$map" 2>/dev/null \
    | awk -v label="${label}:" '
        $1 == label {
          v=$2
          unit=$3
          gsub(/,/, "", v)
          gsub(/[^A-Za-z]/, "", unit)
          unit=tolower(unit)
          n=v + 0
          mult=1
          if (unit ~ /^k/) mult=1000
          else if (unit ~ /^m/) mult=1000*1000
          else if (unit ~ /^g/) mult=1000*1000*1000
          else if (unit ~ /^t/) mult=1000*1000*1000*1000
          printf "%.0f\n", n * mult
          found=1
          exit
        }
        END { if (!found) print 0 }
      '
}

update_map_status() {
  BAD_BYTES=0
  NON_TRIED_BYTES=0
  NON_TRIMMED_BYTES=0
  NON_SCRAPED_BYTES=0

  if [[ -s "$MAPFILE" ]] && have ddrescuelog; then
    BAD_BYTES="$(map_metric_bytes "$MAPFILE" bad-sector)"
    NON_TRIED_BYTES="$(map_metric_bytes "$MAPFILE" non-tried)"
    NON_TRIMMED_BYTES="$(map_metric_bytes "$MAPFILE" non-trimmed)"
    NON_SCRAPED_BYTES="$(map_metric_bytes "$MAPFILE" non-scraped)"
  fi

  UNRESOLVED_BYTES=$(( BAD_BYTES + NON_TRIED_BYTES + NON_TRIMMED_BYTES + NON_SCRAPED_BYTES ))
  log "Mapfile unresolved bytes: bad=${BAD_BYTES} non-tried=${NON_TRIED_BYTES} non-trimmed=${NON_TRIMMED_BYTES} non-scraped=${NON_SCRAPED_BYTES}"
}

run_ddrescue() {
  local timeout_value="${DDRESCUE_PASS_TIMEOUT:-}"
  if [[ -n "$timeout_value" && "$timeout_value" != "0" ]]; then
    log "Watchdog: timeout --foreground --kill-after=60s ${timeout_value} ddrescue $*"
    timeout --foreground --kill-after=60s "$timeout_value" ddrescue "$@"
  else
    ddrescue "$@"
  fi
}

image_source() {
  local dev="$1" mtype="$2" base="$3"
  IMAGE="${SCRATCH_DIR}/${base}.img"
  MAPFILE="${IMAGE}.map"

  local bs_args=()
  case "$mtype" in
    cd|dvd|optical) BSARG="-b 2048"; bs_args=(-b 2048) ;;
    *)              BSARG="" ;;
  esac

  phase "ddrescue fast pass"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY RUN: would run: ddrescue ${bs_args[*]} -f -n '$dev' '$IMAGE' '$MAPFILE'"
    : > "$IMAGE"; : > "$MAPFILE"
    IMAGING_RC=0
  else
    set +e
    run_ddrescue "${bs_args[@]}" -f -n "$dev" "$IMAGE" "$MAPFILE"
    IMAGING_RC=$?
    set -e
  fi
  log "Fast pass exit=$IMAGING_RC"
  if [[ "$IMAGING_RC" == "124" || "$IMAGING_RC" == "137" ]]; then
    warn "Fast pass hit DDRESCUE_PASS_TIMEOUT=${DDRESCUE_PASS_TIMEOUT}; continuing with the mapfile state recovered so far."
  fi

  phase "ddrescue retry pass (-d -r${RETRIES:-4})"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY RUN: would run retry pass"
  else
    set +e
    run_ddrescue "${bs_args[@]}" -d -r"${RETRIES:-4}" "$dev" "$IMAGE" "$MAPFILE"
    IMAGING_RC=$?
    set -e
  fi
  log "Retry pass exit=$IMAGING_RC"
  if [[ "$IMAGING_RC" == "124" || "$IMAGING_RC" == "137" ]]; then
    warn "Retry pass hit DDRESCUE_PASS_TIMEOUT=${DDRESCUE_PASS_TIMEOUT}; continuing with the mapfile state recovered so far."
  fi

  # After both passes, the image must exist and have nonzero size. If
  # ddrescue exited with a CLI / device-open error we'd otherwise sail
  # right into the mount step with an empty file and produce a confusing
  # message there. Bail early instead.
  if [[ "$DRY_RUN" != "1" ]]; then
    if [[ ! -s "$IMAGE" ]]; then
      fatal "ddrescue produced an empty image at $IMAGE — check the session log for the actual error before retrying."
    fi
  fi

  update_map_status

  DEEP_RC=0
  if (( UNRESOLVED_BYTES > 0 )); then
    if [[ -n "${AUTO_DEEP_SCRAPE:-}" ]] || confirm "Run deep-scrape (reverse, -r${DEEP_RETRIES:-16})?" Y; then
      phase "ddrescue deep-scrape (-d -R -r${DEEP_RETRIES:-16})"
      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY RUN: would run deep-scrape"
      else
        set +e
        run_ddrescue "${bs_args[@]}" -d -R -r"${DEEP_RETRIES:-16}" "$dev" "$IMAGE" "$MAPFILE"
        DEEP_RC=$?
        set -e
      fi
      log "Deep-scrape exit=$DEEP_RC"
      if [[ "$DEEP_RC" == "124" || "$DEEP_RC" == "137" ]]; then
        warn "Deep-scrape hit DDRESCUE_PASS_TIMEOUT=${DDRESCUE_PASS_TIMEOUT}; keeping the mapfile so the run can be resumed later."
      fi
      update_map_status
    fi
  fi
}

# ---------- fallback tools -------------------------------------------------
# Each fallback writes a SEPARATE artifact next to the primary image. We do
# NOT auto-merge into the ddrescue mapfile — dvdisaster and safecopy both
# zero-fill unreadable sectors in their output, so blindly folding their
# images back via ddrescue would overwrite *good* data with zeros. The
# operator inspects the artifacts after the run and decides what to keep.
# FALLBACK_ARTIFACTS is the list of paths to mention in the final report.
FALLBACK_ARTIFACTS=()
APM_NEEDS_RESCUE=0
HYBRID_DISC=0
run_fallbacks() {
  local dev="$1" mtype="$2"
  (( UNRESOLVED_BYTES > 0 )) || { log "No unresolved sectors remain; skipping fallback tools."; return; }
  [[ -z "${FALLBACK_TOOLS:-}" ]] && { log "No FALLBACK_TOOLS configured."; return; }

  IFS=',' read -r -a tools <<<"$FALLBACK_TOOLS"
  for tool in "${tools[@]}"; do
    tool="${tool// /}"
    [[ -z "$tool" ]] && continue
    case "$tool" in
      dvdisaster)
        if [[ "$mtype" != "cd" && "$mtype" != "dvd" && "$mtype" != "optical" ]]; then
          log "Skipping dvdisaster (non-optical media)"; continue
        fi
        if ! have dvdisaster; then warn "dvdisaster not installed; skipping"; continue; fi
        local dvdi="${IMAGE}.dvdisaster.iso"
        phase "Fallback: dvdisaster --read -> ${dvdi}"
        if [[ "$DRY_RUN" == "1" ]]; then
          log "DRY RUN: would run dvdisaster"
        else
          # Minimal portable invocation — older dvdisaster versions don't
          # all accept --read-attempts. Each read retries internally.
          set +e
          dvdisaster -d "$dev" -i "$dvdi" --read || true
          set -e
          [[ -f "$dvdi" ]] && FALLBACK_ARTIFACTS+=("$dvdi")
        fi
        ;;
      cdparanoia)
        if [[ "$mtype" != "cd" ]]; then
          log "Skipping cdparanoia (not a CD)"; continue
        fi
        if ! have cdparanoia; then warn "cdparanoia not installed; skipping"; continue; fi
        local audio_dir="${SCRATCH_DIR}/$(basename "${IMAGE%.img}")-audio"
        phase "Fallback: cdparanoia -> ${audio_dir}"
        if [[ "$DRY_RUN" == "1" ]]; then
          log "DRY RUN: would run cdparanoia"
        else
          mkdir -p "$audio_dir"
          ( cd "$audio_dir" && cdparanoia -B -d "$dev" || true )
          [[ -n "$(ls -A "$audio_dir" 2>/dev/null)" ]] && FALLBACK_ARTIFACTS+=("$audio_dir")
        fi
        ;;
      safecopy)
        if ! have safecopy; then warn "safecopy not installed; skipping"; continue; fi
        local sc="${IMAGE}.safecopy.img"
        local sc_bad="${IMAGE}.safecopy.bad"
        phase "Fallback: safecopy (3 stages) -> ${sc}"
        if [[ "$DRY_RUN" == "1" ]]; then
          log "DRY RUN: would run safecopy stages"
        else
          set +e
          # safecopy syntax: safecopy [opts] SRC DEST ; -B writes the bad-block list
          safecopy --stage1 -B "$sc_bad" "$dev" "$sc" 2>&1 || true
          safecopy --stage2 -B "$sc_bad" "$dev" "$sc" 2>&1 || true
          safecopy --stage3 -B "$sc_bad" "$dev" "$sc" 2>&1 || true
          set -e
          [[ -f "$sc" ]] && FALLBACK_ARTIFACTS+=("$sc")
          [[ -f "$sc_bad" ]] && FALLBACK_ARTIFACTS+=("$sc_bad")
        fi
        ;;
      *) warn "Unknown fallback tool: $tool" ;;
    esac
  done

  if (( ${#FALLBACK_ARTIFACTS[@]} > 0 )); then
    log "Fallback artifacts produced (kept separate from the ddrescue image):"
    printf '   - %s\n' "${FALLBACK_ARTIFACTS[@]}"
    log "Compare these against the ddrescue image manually; see docs/recovery_strategies.md."
  fi
}

# ---------- mount image and copy to archive destination ---------------------
# parted's "fs-name" column uses names that aren't always valid mount -t
# values. Map known divergences.
parted_to_mount_fstype() {
  case "$1" in
    fat16|fat32) echo "vfat" ;;
    ntfs)        echo "ntfs-3g" ;;  # mount -t ntfs is read-only on most kernels
    linux-swap*) echo "" ;;          # skip
    *)           echo "$1" ;;
  esac
}

# Explicit cleanup helper rather than a RETURN trap. RETURN traps in bash
# fire on every subsequent function return for the rest of the script,
# which would unmount the wrong thing later.
_cleanup_mount() {
  local mnt="$1"
  [[ -z "$mnt" ]] && return 0
  umount "$mnt" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
}

# Inspect an image with parted -m and return its partition-table type
# (the 6th colon-separated field of the device line). Empty if parted
# can't read the image. Values seen in the wild: msdos, gpt, mac, loop.
partition_table_type() {
  local image="$1"
  parted -m -s "$image" unit B print 2>/dev/null \
    | awk -F: 'NR==2 {print $6; exit}'
}

# Walk an Apple Partition Map image looking for HFS/HFS+ data partitions
# and mount the first one that mounts cleanly. APM partition 1 is always
# the partition map descriptor itself; data partitions are typically
# named "Apple_HFS" / "Apple_HFSX" in the parted NAME column (field 6),
# and may or may not populate the FS column (field 5).
#
# Args: $1=image, $2=mountpoint
# Returns: 0 on successful mount + sets APM_MOUNTED_OFFSET / APM_MOUNTED_FS
#          for the report; non-zero if no HFS partition mounted.
APM_MOUNTED_OFFSET=""
APM_MOUNTED_FS=""
APM_HFS_PART_COUNT=0
walk_apm_hfs() {
  local image="$1" mnt="$2"
  local parted_out
  parted_out="$(parted -m -s "$image" unit B print 2>/dev/null || true)"
  [[ -z "$parted_out" ]] && return 1

  # Collect every partition line whose FS or NAME smells like HFS.
  # Format per line: NUMBER:START:END:SIZE:FS:NAME:FLAGS
  local hfs_lines
  hfs_lines="$(awk -F: 'NR>2 && (tolower($5) ~ /hfs/ || tolower($6) ~ /hfs/) {print}' <<<"$parted_out")"
  if [[ -z "$hfs_lines" ]]; then
    return 1
  fi
  APM_HFS_PART_COUNT="$(printf '%s\n' "$hfs_lines" | grep -c .)"

  while IFS= read -r line; do
    local num off raw_fs name
    num="$(awk -F: '{print $1}' <<<"$line")"
    off="$(awk -F: '{sub(/B$/,"",$2); print $2}' <<<"$line")"
    raw_fs="$(awk -F: '{print $5}' <<<"$line")"
    name="$(awk -F: '{print $6}' <<<"$line")"
    [[ -z "$off" || "$off" == "0" ]] && continue
    log "APM partition ${num} (${name:-no-name}, parted-fs=${raw_fs:-?}, offset=${off}B): trying HFS mount"
    for fstype in hfsplus hfs; do
      if mount -o "loop,ro,offset=${off}" -t "$fstype" "$image" "$mnt" 2>/dev/null; then
        APM_MOUNTED_OFFSET="$off"
        APM_MOUNTED_FS="$fstype"
        log "Mounted APM partition ${num} as ${fstype} at offset ${off}B"
        return 0
      fi
    done
  done <<<"$hfs_lines"

  return 1
}

# Print a hard-to-miss banner pointing the operator at menu option 3 when
# we can see this is APM-partitioned but can't mount any HFS partition
# directly. Keeps the image on disk (cleanup is gated separately) so the
# rescue script has something to walk.
apm_loud_prompt() {
  local image="$1" parted_dump="$2"
  cat >&2 <<EOF


****************************************************************************
*  APPLE PARTITION MAP (APM) DETECTED — manual rescue recommended           *
****************************************************************************

This image has an Apple Partition Map (parted reports table type 'mac').
That's the layout used by old-Mac install discs, System 7-9 / early
OS X HDDs, and some hybrid Mac/PC CDs.

I imaged it cleanly, but I could not mount its HFS/HFS+ partitions via the
kernel here. Reasons range from "kernel hfs driver doesn't know this exact
variant" to "the volume needs hfsutils to walk".

What to do next:

  1. KEEP THE IMAGE. It is at:
        ${image}
     Do NOT answer 'y' to the cleanup prompt at the end of this run.

  2. Run menu option 3 (Rescue Apple Partition Map) against the image:
        sudo ./disktools.sh rescue
     When asked for the source, point it at ${image} interpreted as a
     loop device — set it up first:
        sudo losetup --show -fP --read-only ${image}
     parted will then see the APM partitions and the rescue script's
     hfsutils fallback can extract files even when the kernel can't
     mount the volume.

  3. Or extract a single HFS partition manually using the parted output
     below (offset = field 2, in bytes):

EOF
  printf '%s\n' "$parted_dump" >&2
  cat >&2 <<EOF

        sudo dd if=${image} of=hfs-part.img bs=1 skip=<OFFSET> count=<SIZE>
        sudo hmount hfs-part.img && hls -l    # browse with hfsutils
        # or: sudo mount -o loop,ro -t hfsplus hfs-part.img /mnt/x

  4. The session log + raw image are tagged in this run's report so you
     can come back to them. See: ${SESSION_LOG}

****************************************************************************

EOF
}

copy_to_nas() {
  local image="$1" case_dir="$2"
  local mnt rc=0
  mnt="$(mktemp -d -t archive-mnt-XXXX)"

  local fs_desc
  fs_desc="$(file -b "$image" 2>/dev/null || echo unknown)"
  log "Image FS guess: $fs_desc"

  local mounted=0 primary_fs=""
  for fstype in iso9660 udf vfat ntfs-3g hfsplus hfs ext4 ext3 ext2; do
    if mount -o loop,ro -t "$fstype" "$image" "$mnt" 2>/dev/null; then
      log "Mounted $image as $fstype"
      mounted=1; primary_fs="$fstype"; break
    fi
  done

  local table_type=""
  if (( mounted == 0 )); then
    table_type="$(partition_table_type "$image")"
    log "Partition table type: ${table_type:-unknown}"

    if [[ "$table_type" == "mac" ]]; then
      # APM-partitioned image. Walk HFS/HFS+ partitions specifically
      # before falling back to the first-usable-partition probe — APM's
      # partition 1 is always the partition map descriptor, never data.
      if walk_apm_hfs "$image" "$mnt"; then
        mounted=1
      fi
    fi
  fi

  if (( mounted == 0 )); then
    # Probe the partition table for the first usable partition. parted -m
    # uses ':' as field separator: NUMBER:START:END:SIZE:FS:NAME:FLAGS
    local p_line off raw_fs fstype
    p_line="$(parted -m -s "$image" unit B print 2>/dev/null \
              | awk -F: 'NR>2 && $5!="" && $5!="free" {print; exit}')"
    if [[ -n "$p_line" ]]; then
      off="$(awk -F: '{sub(/B$/,"",$2); print $2}' <<<"$p_line")"
      raw_fs="$(awk -F: '{print $5}' <<<"$p_line")"
      fstype="$(parted_to_mount_fstype "$raw_fs")"
      if [[ -n "$fstype" && -n "$off" ]]; then
        log "Trying partition at offset ${off} (parted said '$raw_fs' → mount -t '$fstype')"
        mount -o "loop,ro,offset=${off}" -t "$fstype" "$image" "$mnt" 2>/dev/null && mounted=1
      else
        warn "Found partition at offset ${off:-?} with fs '${raw_fs:-?}' but no mount-friendly type — skipping."
      fi
    fi
  fi

  if (( mounted == 0 )); then
    if [[ "$table_type" == "mac" ]]; then
      # APM detected but no HFS partition mounted automatically. Print
      # the loud rescue-helper guidance and keep the raw image.
      apm_loud_prompt "$image" "$(parted -m -s "$image" unit B print 2>/dev/null || true)"
      APM_NEEDS_RESCUE=1
    else
      warn "Could not mount image; copying raw image only."
    fi
    cp -av "$image" "$case_dir/"
    fix_owner "$case_dir"
    _cleanup_mount "$mnt"
    return 1
  fi

  # Hybrid Mac/PC disc detection: ISO9660 / UDF primary mount succeeded,
  # but the same image may also have an HFS view (APM table OR an
  # HFS-flavored partition). Old shareware/game/install CDs often store
  # Mac-specific apps + resource forks on the HFS side that the
  # ISO9660 side doesn't even list. Capture both views into subdirs.
  local is_hybrid=0
  if [[ "$primary_fs" == "iso9660" || "$primary_fs" == "udf" ]]; then
    local hybrid_table_type
    hybrid_table_type="$(partition_table_type "$image")"
    if [[ "$hybrid_table_type" == "mac" ]]; then
      is_hybrid=1
    elif parted -m -s "$image" unit B print 2>/dev/null \
           | awk -F: 'NR>2 && (tolower($5) ~ /hfs/ || tolower($6) ~ /hfs/) {found=1} END{exit !found}'; then
      is_hybrid=1
    fi
    (( is_hybrid == 1 )) && log "Hybrid Mac/PC disc detected (primary=${primary_fs}, HFS view also present)."
  fi

  if (( is_hybrid == 1 )); then
    HYBRID_DISC=1
    mkdir -p "$case_dir/${primary_fs}" "$case_dir/hfs"

    log "rsync (${primary_fs} view) $mnt/ -> $case_dir/${primary_fs}/"
    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY RUN: would rsync ${primary_fs} view"
    else
      rsync -aHAX --info=progress2 "$mnt/" "$case_dir/${primary_fs}/" \
        || { warn "rsync (${primary_fs} view) reported issues; see log."; rc=1; }
    fi
    _cleanup_mount "$mnt"

    # Mount the HFS view. Prefer the APM walker if the table is 'mac';
    # otherwise try a direct hfsplus/hfs mount at offset 0 (some hybrid
    # CDs put the HFS volume header at sector 0 without an APM map).
    mnt="$(mktemp -d -t archive-mnt-XXXX)"
    local hfs_mounted=0
    if [[ "$hybrid_table_type" == "mac" ]] && walk_apm_hfs "$image" "$mnt"; then
      hfs_mounted=1
    else
      for fstype in hfsplus hfs; do
        if mount -o loop,ro -t "$fstype" "$image" "$mnt" 2>/dev/null; then
          log "Mounted hybrid HFS view as $fstype (offset 0)"
          hfs_mounted=1; break
        fi
      done
    fi

    if (( hfs_mounted == 1 )); then
      log "rsync (hfs view) $mnt/ -> $case_dir/hfs/"
      if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY RUN: would rsync hfs view"
      else
        rsync -aHAX --info=progress2 "$mnt/" "$case_dir/hfs/" \
          || { warn "rsync (hfs view) reported issues; see log."; rc=1; }
      fi
    else
      warn "Hybrid disc detected but HFS view did not mount. ${primary_fs} captured at $case_dir/${primary_fs}/."
      warn "Image kept at $image — run option 3 to extract the Mac side manually."
      APM_NEEDS_RESCUE=1
      rmdir "$case_dir/hfs" 2>/dev/null || true
    fi
    fix_owner "$case_dir"
    _cleanup_mount "$mnt"
    return $rc
  fi

  log "rsync $mnt/ -> $case_dir/"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY RUN: would rsync"
  else
    rsync -aHAX --info=progress2 "$mnt/" "$case_dir/" || { warn "rsync reported issues (encoding, sparse files); see log."; rc=1; }
  fi
  fix_owner "$case_dir"
  _cleanup_mount "$mnt"
  return $rc
}

# ---------- report ---------------------------------------------------------
write_report() {
  local case_dir="$1" report="$2"
  {
    echo "===== ARCHIVE CASE REPORT ====="
    echo "Timestamp (UTC): $TS"
    echo "Source device:   ${SRC}"
    echo "Media type:      ${MTYPE}"
    echo "Case name:       ${NAME}"
    echo "Image:           ${IMAGE}"
    echo "Mapfile:         ${MAPFILE}"
    echo "Archive destination: ${case_dir}"
    echo
    echo "---- Imaging ----"
    echo "ddrescue pass timeout: ${DDRESCUE_PASS_TIMEOUT:-disabled}"
    echo "ddrescue retry rc: ${IMAGING_RC:-?}"
    echo "ddrescue deep-scrape rc: ${DEEP_RC:-skipped}"
    echo "Bad bytes remaining: ${BAD_BYTES:-?}"
    echo "Non-tried bytes remaining: ${NON_TRIED_BYTES:-?}"
    echo "Non-trimmed bytes remaining: ${NON_TRIMMED_BYTES:-?}"
    echo "Non-scraped bytes remaining: ${NON_SCRAPED_BYTES:-?}"
    echo "Total unresolved bytes: ${UNRESOLVED_BYTES:-?}"
    echo
    echo "---- Mapfile summary ----"
    if [[ -s "$MAPFILE" ]] && have ddrescuelog; then
      ddrescuelog -t "$MAPFILE" || true
    else
      echo "(no mapfile)"
    fi
    echo
    if (( ${#FALLBACK_ARTIFACTS[@]} > 0 )); then
      echo "---- Fallback artifacts (kept separate; do not merge blindly) ----"
      printf '  %s\n' "${FALLBACK_ARTIFACTS[@]}"
      echo
    fi
    if (( HYBRID_DISC == 1 )); then
      echo "---- Hybrid Mac/PC disc ----"
      echo "Both views captured into separate subdirectories of:"
      echo "  ${case_dir}/"
      echo "    iso9660/  (or udf/) — PC-readable view"
      echo "    hfs/                 — Mac view (Mac-only files + resource forks)"
      echo "Content typically overlaps but is not identical; Mac-only items"
      echo "(installers, classic Mac apps) usually live only under hfs/."
      echo
    fi
    if (( APM_NEEDS_RESCUE == 1 )); then
      echo "---- APM rescue required ----"
      echo "Image is Apple Partition Map (table type 'mac') and could not"
      echo "be auto-mounted. Image kept at: ${IMAGE}"
      echo "Next step: sudo ./disktools.sh rescue   (menu option 3)"
      echo "See session log for the full APM banner with parted output."
      echo
    fi
    echo "---- Destination listing ----"
    ls -la "$case_dir" 2>/dev/null | head -50
    echo
    echo "Session log: $SESSION_LOG"
  } >"$report"
  fix_owner "$report"
}

# ---------- main -----------------------------------------------------------
log "archive_media.sh starting"
log "Config:        $CONFIG_FILE"
log "Session log:   $SESSION_LOG"
log "Scratch dir:   $SCRATCH_DIR"
log "Archive dest:  $NAS_DEST"
log "DRY_RUN=$DRY_RUN AUTO=$AUTO"

ensure_nas_mounted
pick_device "${1:-}"
guard_device "$SRC"

# Default media type from detect_media.sh
DEFAULT_MTYPE="$(bash "${SCRIPT_DIR}/detect_media.sh" --tsv | awk -F'\t' -v d="$SRC" 'NR>1 && $1==d {print $2; exit}')"
DEFAULT_MTYPE="${DEFAULT_MTYPE:-hdd}"
case "$DEFAULT_MTYPE" in
  optical) DEFAULT_MTYPE="cd" ;;
esac

if [[ "$AUTO" == "1" ]]; then
  MTYPE="${MTYPE_OVERRIDE:-$DEFAULT_MTYPE}"
  SUGGESTED_NAME="$(suggest_case_name "$SRC" "$MTYPE")"
  NAME="${NAME_OVERRIDE:-${SUGGESTED_NAME:-auto-${TS}}}"
else
  read -rp "Media type [cd|dvd|zip|hdd] (default: ${DEFAULT_MTYPE}): " MTYPE
  MTYPE="${MTYPE:-$DEFAULT_MTYPE}"
  SUGGESTED_NAME="$(suggest_case_name "$SRC" "$MTYPE")"
  if [[ -n "$SUGGESTED_NAME" ]]; then
    read -rp "Disc folder name [detected: \"${SUGGESTED_NAME}\"]: " NAME
    NAME="${NAME:-$SUGGESTED_NAME}"
  else
    read -rp "Disc folder name (no spaces): " NAME
  fi
  [[ -z "$NAME" ]] && fatal "Case name is required."
fi

case "$MTYPE" in cd|dvd|zip|hdd|optical) ;; *) fatal "Bad media type: $MTYPE" ;; esac
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "Case name must match [A-Za-z0-9._-]"
guard_media_present "$SRC" "$MTYPE"

BASE="${MTYPE}-${NAME}-${TS}"
CASE_DIR="${NAS_DEST}/${BASE}"
mkdir -p "$CASE_DIR"
fix_owner "$CASE_DIR"

phase "Plan"
echo "Source:      $SRC"
echo "Media type:  $MTYPE"
echo "Case base:   $BASE"
echo "Image (loc): ${SCRATCH_DIR}/${BASE}.img"
echo "Dest:        $CASE_DIR"
pause "Plan looks right?"

image_source "$SRC" "$MTYPE" "$BASE"
run_fallbacks "$SRC" "$MTYPE"

phase "Mount image and copy to archive destination"
copy_to_nas "$IMAGE" "$CASE_DIR" || warn "Copy step had issues."

REPORT="${CASE_DIR}/report.txt"
write_report "$CASE_DIR" "$REPORT"
log "Report: $REPORT"
cp -f "$REPORT" "${REPORT_ROOT}/${BASE}-report.txt" || true
fix_owner "${REPORT_ROOT}"

phase "Cleanup"
if (( APM_NEEDS_RESCUE == 1 )); then
  log "APM rescue is pending — keeping image at ${IMAGE} (skipping cleanup prompt)."
  log "Run: sudo ./disktools.sh rescue   to walk the APM partitions."
elif confirm "Delete local image and mapfile (${IMAGE} / ${MAPFILE})?" N; then
  rm -f -- "$IMAGE" "$MAPFILE" 2>/dev/null || true
  log "Local scratch image+mapfile cleaned."
  if (( ${#FALLBACK_ARTIFACTS[@]} > 0 )); then
    log "Fallback artifacts left in place (separate files; inspect manually):"
    printf '   - %s\n' "${FALLBACK_ARTIFACTS[@]}"
  fi
else
  log "Kept image at ${IMAGE} (mapfile ${MAPFILE})."
fi

if [[ "$MTYPE" == "cd" || "$MTYPE" == "dvd" || "$MTYPE" == "optical" ]]; then
  if have eject && [[ "$DRY_RUN" != "1" ]]; then
    eject "$SRC" 2>/dev/null || true
  fi
fi

log "Done. Case at: $CASE_DIR"
