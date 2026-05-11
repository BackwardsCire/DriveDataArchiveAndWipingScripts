#! /usr/bin/env bash
# detect_media.sh - Enumerate candidate source media for archiving.
#
# Lists every block device the kernel currently knows about, tags it as
# zip / optical / usb-hdd / hdd / other, and notes whether media is inserted
# and readable. The system disk is excluded.
#
# Usage:
#   ./detect_media.sh            # human-readable table
#   ./detect_media.sh --tsv      # machine-readable: one row per device
#   ./detect_media.sh --json     # JSON array (requires lsblk JSON support)
#
# Exit codes:
#   0   success (zero or more devices listed)
#   1   missing required tool

set -Eeuo pipefail

MODE="human"
case "${1:-}" in
  --tsv)  MODE="tsv" ;;
  --json) MODE="json" ;;
  -h|--help)
    sed -n '2,12p' "$0"; exit 0 ;;
  "") ;;
  *) echo "Unknown arg: $1" >&2; exit 1 ;;
esac

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
require lsblk
require udevadm
require findmnt
require awk

# -------- system disk so we never offer to image it ------------------------
SYS_PARENT=""
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [[ -n "$ROOT_SRC" ]]; then
  SYS_PARENT="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)"
  [[ -z "$SYS_PARENT" ]] && SYS_PARENT="$(basename "$ROOT_SRC")"
fi

# -------- classify a device ------------------------------------------------
# Echoes one of: zip | optical | usb-hdd | hdd | other
classify() {
  local dev="$1" type="$2" tran="$3" rm_flag="$4" size_bytes="$5" vendor="$6" model="$7"
  local v="${vendor,,}" m="${model,,}"

  if [[ "$type" == "rom" ]]; then echo "optical"; return; fi

  # Iomega Zip / Jaz drives — vendor/model is the most reliable signal.
  if [[ "$v" == *iomega* ]] || [[ "$m" == *zip* ]] || [[ "$m" == *jaz* ]]; then
    echo "zip"; return
  fi
  # Heuristic by size for legacy Zip media (96–98 MB / 240 MB / 740–750 MB)
  # only when the device looks removable. Avoids tagging tiny SD cards.
  if [[ "$rm_flag" == "1" && -n "$size_bytes" && "$size_bytes" != "0" ]]; then
    local mb=$(( size_bytes / 1024 / 1024 ))
    if (( mb >= 95 && mb <= 105 )) || (( mb >= 235 && mb <= 250 )) || (( mb >= 735 && mb <= 760 )); then
      echo "zip"; return
    fi
  fi

  if [[ "$tran" == "usb" ]]; then echo "usb-hdd"; return; fi
  if [[ "$type" == "disk" ]]; then echo "hdd"; return; fi
  echo "other"
}

# -------- read one device's properties -------------------------------------
# Sets globals: NAME TYPE SIZE_H SIZE_B MODEL VENDOR SERIAL TRAN RM RO MOUNTPOINTS
read_props() {
  local dev="$1"
  # lsblk -P quotes values; eval is safe-ish here because lsblk escapes quotes.
  local line
  line="$(lsblk -d -P -b -o NAME,TYPE,SIZE,MODEL,VENDOR,SERIAL,TRAN,RM,RO,MOUNTPOINTS "$dev" 2>/dev/null || true)"
  [[ -z "$line" ]] && return 1
  # Reset
  NAME=""; TYPE=""; SIZE_B=""; MODEL=""; VENDOR=""; SERIAL=""; TRAN=""; RM=""; RO=""; MOUNTPOINTS=""
  eval "$line"
  SIZE_H="$(numfmt --to=iec --suffix=B "${SIZE:-0}" 2>/dev/null || echo "${SIZE:-0}B")"
  SIZE_B="${SIZE:-0}"
}

# -------- inspect what's on the medium -------------------------------------
# Echoes a short description: "iso9660", "vfat", "hfs", "blank", "no medium",
# "unreadable", "unknown".
probe_medium() {
  local dev="$1" kind="$2" size_b="$3"
  if [[ "$kind" == "optical" ]]; then
    # /sys/block/<name>/size is in 512-byte sectors; 0 == no disc.
    local short="${dev##*/}"
    local sectors
    sectors="$(cat "/sys/block/${short}/size" 2>/dev/null || echo 0)"
    if [[ "$sectors" == "0" ]]; then echo "no medium"; return; fi
  elif [[ "$size_b" == "0" || -z "$size_b" ]]; then
    echo "no medium"; return
  fi

  local fs
  fs="$(udevadm info --query=property --name="$dev" 2>/dev/null \
        | awk -F= '$1=="ID_FS_TYPE"{print $2; exit}')"
  if [[ -n "$fs" ]]; then echo "$fs"; return; fi

  # Fall back to file -s on the raw device. `file` writes its read errors to
  # stdout (not stderr) and exits non-zero, so check the exit code rather
  # than scraping the message.
  local sig rc
  sig="$(file -bs "$dev" 2>/dev/null)" && rc=0 || rc=$?
  if (( rc != 0 )); then echo "unreadable"; return; fi
  case "${sig,,}" in
    *iso\ 9660*|*udf\ filesystem*) echo "iso9660" ;;
    *hfs*)                         echo "hfs" ;;
    *fat*|*vfat*)                  echo "vfat" ;;
    *ntfs*)                        echo "ntfs" ;;
    *ext[234]*)                    echo "ext" ;;
    *data*|"")                     echo "unknown" ;;
    *)                             echo "${sig:0:24}" ;;
  esac
}

# -------- collect rows -----------------------------------------------------
# Internal separator: ASCII Unit Separator (\x1f). Using a non-whitespace
# delimiter is required so that `read` preserves empty fields like an empty
# MOUNTPOINTS column — bash's read collapses consecutive whitespace IFS.
US=$'\x1f'
ROWS=()  # fields: dev kind type size_h size_b vendor model tran rm ro mountpoints fs

# Strip the trailing/embedded whitespace lsblk likes to pad string fields with.
clean() { local s="${1-}"; s="${s%"${s##*[![:space:]]}"}"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "$s"; }
json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Enumerate every disk and rom block device
while IFS= read -r dev; do
  [[ -z "$dev" ]] && continue
  read_props "$dev" || continue

  # Skip the system disk and its partitions
  if [[ -n "$SYS_PARENT" && "$NAME" == "$SYS_PARENT" ]]; then continue; fi

  KIND="$(classify "$dev" "$TYPE" "$TRAN" "$RM" "$SIZE_B" "$VENDOR" "$MODEL")"
  FS="$(probe_medium "$dev" "$KIND" "$SIZE_B")"

  ROWS+=("${dev}${US}${KIND}${US}${TYPE}${US}${SIZE_H}${US}${SIZE_B}${US}$(clean "${VENDOR-}")${US}$(clean "${MODEL-}")${US}${TRAN-}${US}${RM:-0}${US}${RO:-0}${US}$(clean "${MOUNTPOINTS-}")${US}${FS}")
done < <(lsblk -dn -p -o NAME,TYPE | awk '$2=="disk" || $2=="rom" {print $1}')

# -------- output -----------------------------------------------------------
case "$MODE" in
  tsv)
    printf 'device\tkind\ttype\tsize\tsize_bytes\tvendor\tmodel\ttran\tremovable\treadonly\tmountpoints\tfs\n'
    for row in "${ROWS[@]}"; do printf '%s\n' "${row//${US}/$'\t'}"; done
    ;;
  json)
    printf '['
    first=1
    for row in "${ROWS[@]}"; do
      IFS="$US" read -r dev kind type size sb vendor model tran rm ro mp fs <<<"$row"
      [[ $first -eq 0 ]] && printf ','
      first=0
      printf '{"device":"%s","kind":"%s","type":"%s","size":"%s","size_bytes":%s,"vendor":"%s","model":"%s","tran":"%s","removable":%s,"readonly":%s,"mountpoints":"%s","fs":"%s"}' \
        "$(json_escape "$dev")" "$(json_escape "$kind")" "$(json_escape "$type")" "$(json_escape "$size")" "${sb:-0}" \
        "$(json_escape "$vendor")" "$(json_escape "$model")" "$(json_escape "$tran")" "${rm:-0}" "${ro:-0}" \
        "$(json_escape "$mp")" "$(json_escape "$fs")"
    done
    printf ']\n'
    ;;
  human|*)
    if (( ${#ROWS[@]} == 0 )); then
      echo "No candidate source media found (system disk excluded)."
      exit 0
    fi
    printf '%-12s %-8s %-10s %-22s %-8s %-12s\n' "DEVICE" "KIND" "SIZE" "MODEL" "TRAN" "FS/STATE"
    printf '%-12s %-8s %-10s %-22s %-8s %-12s\n' "------" "----" "----" "-----" "----" "--------"
    for row in "${ROWS[@]}"; do
      IFS="$US" read -r dev kind type size sb vendor model tran rm ro mp fs <<<"$row"
      mdl="${model:0:22}"
      fs_disp="${fs:0:12}"
      printf '%-12s %-8s %-10s %-22s %-8s %-12s\n' "$dev" "$kind" "$size" "${mdl:-?}" "${tran:-?}" "${fs_disp:-?}"
      if [[ -n "$mp" ]]; then
        printf '             mounted at: %s\n' "$mp"
      fi
    done
    echo
    echo "Tip: run 'scripts/archive_media.sh <device>' to image one of these to the configured archive destination."
    ;;
esac
