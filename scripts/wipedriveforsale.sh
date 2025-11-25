#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

###############################################################################
# wipedriveforsale.sh - USB-focused drive prep (Ubuntu 25.04)
#
# - Wipe: NVMe -> nvme format -s1; others -> nwipe (DoD short, verify last)
# - Sector test: badblocks (read-only, live progress)
# - SMART: auto-detect over USB bridges; concise buyer-facing summary
# - PDF report: clean banner (no absolute paths / usernames)
# - Final classification: SUCCESS/ or FAILED/
#
# Env toggles:
#   DEBUG=1                 # shell tracing to session log
#   ALLOW_NONUSB=0          # enforce USB/removable only (default block)
#   PAUSE=1                 # prompt after each major STEP (for debugging)
#
# Dry run toggles (no disk changes; for testing):
#   DRY_RUN=1               # simulate nwipe/wipefs/badblocks
#   DRY_NWIPE_FAIL=1        # simulate nwipe failure (only if DRY_RUN=1)
#   DRY_BADBLOCKS_FAIL=1    # simulate badblocks failure (only if DRY_RUN=1)
#   DRY_ALLOW_FAKE_DEVICE=1 # allow non-block path while DRY_RUN=1
#   ALLOW_NWIPE_ON_NVME=0   # if nvme format fails, allow nwipe attempt on NVMe (off by default)
#
# Usage:
#   sudo ./wipedriveforsale.sh /dev/sdX     # e.g., /dev/sdb (USB)
###############################################################################

# ====== STEP 0: Globals & helpers ============================================
DEBUG="${DEBUG:-0}"
TS_START="$(date -u +'%Y%m%dT%H%M%SZ')"
WIPE_METHOD="unknown"
WIPE_LOG_APPLIES=1

# Dry run toggles
DRY_RUN="${DRY_RUN:-0}"
DRY_NWIPE_FAIL="${DRY_NWIPE_FAIL:-0}"
DRY_BADBLOCKS_FAIL="${DRY_BADBLOCKS_FAIL:-0}"
DRY_ALLOW_FAKE_DEVICE="${DRY_ALLOW_FAKE_DEVICE:-0}"

# Pause toggle (debug stepping)
PAUSE="${PAUSE:-0}"
pause_here() {
  if [[ "$PAUSE" = "1" && -t 0 ]]; then
    local msg="${1:-Press Enter to continue...}"
    echo
    read -rp "[PAUSE] $msg"
  fi
}

# Save under the invoking user's home even with sudo
USER_HOME="${SUDO_USER:+/home/$SUDO_USER}"
USER_HOME="${USER_HOME:-$HOME}"
WORKDIR="${USER_HOME}/drive_reports"
mkdir -p "$WORKDIR"

SESSION_LOG="${WORKDIR}/session_${TS_START}.log"
exec > >(tee -a "$SESSION_LOG") 2>&1
[[ "$DEBUG" = "1" ]] && set -x
trap 'ec=$?; echo "ERROR: exit=$ec at line ${LINENO}. Last cmd: ${BASH_COMMAND}" >&2' ERR

timestamp(){ date -u +'%Y-%m-%d %H:%M:%S UTC'; }
phase(){ echo; echo "===== $(timestamp) :: $* ====="; }
run(){ local label="$1"; shift; phase "$label"; local s=$(date +%s) rc; "$@"; rc=$?; local e=$(date +%s); echo "[$label] exit=$rc elapsed=$((e-s))s"; return $rc; }

# ====== STEP 1: Pre-flight ====================================================
if [[ $EUID -ne 0 ]]; then echo "Error: run as root (sudo $0 /dev/XYZ)" >&2; exit 1; fi
if [[ $# -ne 1 ]]; then echo "Usage: $0 /dev/sdX_or_nvmeXn1" >&2; exit 1; fi
DRIVE="$1"

if [[ "$DRY_RUN" = "1" && "$DRY_ALLOW_FAKE_DEVICE" = "1" ]]; then
  echo "DRY RUN: Skipping block-device check for $DRIVE"
else
  [[ -b "$DRIVE" ]] || { echo "Error: $DRIVE is not a block device."; exit 1; }
fi

# Ubuntu 25.04: util-linux (script/findmnt), usbutils (lsusb)
require_cmds=( smartctl lsblk awk sed grep badblocks nwipe enscript ps2pdf nvme wipefs script findmnt lsusb dmesg stdbuf udevadm dpkg-query )
missing=(); for c in "${require_cmds[@]}"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if (( ${#missing[@]} )); then
  echo "Missing required command(s): ${missing[*]}"
  echo "Install with:"
  echo "  sudo apt update && sudo apt install -y smartmontools e2fsprogs nwipe enscript ghostscript nvme-cli util-linux usbutils coreutils"
  exit 1
fi
pause_here "Pre-flight checks passed. Continue?"

# ====== STEP 2: USB/removable guard + system safety ==========================
ALLOW_NONUSB="${ALLOW_NONUSB:-0}"  # default block non-USB/removable
if udevadm info --query=property --name="$DRIVE" 2>/dev/null | grep -q '^ID_BUS=usb'; then
  IS_USB=1
else
  IS_USB=0
fi
RM_FLAG="$(lsblk -dn -o RM "$DRIVE" 2>/dev/null || echo 0)"
if [[ "$ALLOW_NONUSB" = "0" && "$IS_USB" != "1" && "$RM_FLAG" != "1" ]]; then
  echo "FATAL: $DRIVE not detected as USB/removable. Set ALLOW_NONUSB=1 to override."
  exit 1
fi
if [[ "$IS_USB" != "1" ]]; then
  echo "WARN: $DRIVE is not tagged ID_BUS=usb (RM=$RM_FLAG). Proceeding."
fi

ROOTSRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
sys_parents=()
if [[ -n "$ROOTSRC" ]]; then
  pk="$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null | head -n1 || true)"
  if [[ -n "$pk" ]]; then sys_parents+=("$pk")
  else
    while read -r parent; do [[ -n "$parent" ]] && sys_parents+=("$parent"); done \
      < <(lsblk -ndo PKNAME "$(readlink -f "$ROOTSRC")" 2>/dev/null | sort -u)
  fi
fi
TARGET="$(basename "$DRIVE")"
for d in "${sys_parents[@]}"; do
  if [[ "$TARGET" == "$d" ]]; then
    echo "FATAL: $DRIVE appears to be the SYSTEM DISK for '/'. Refusing."
    exit 1
  fi
done
if lsblk -ln -o NAME,MOUNTPOINT "$DRIVE" | awk '$2!=""{exit 0} END{exit 1}'; then
  echo "FATAL: One or more partitions on $DRIVE are mounted. Unmount first:"
  lsblk -ln -o NAME,MOUNTPOINT "$DRIVE" | awk '$2!=""{print "  /dev/"$1" -> "$2}'
  exit 1
fi
pause_here "USB guard & safety checks complete. Continue?"

# ====== STEP 3: Identify drive (lsblk-first) =================================
MODEL="$(lsblk -d -o MODEL "$DRIVE" 2>/dev/null | awk 'NR==2{print $0}')"
SERIAL="$(lsblk -d -o SERIAL "$DRIVE" 2>/dev/null | awk 'NR==2{gsub(/[ \t]/,"");print $0}')"
WWN="$(lsblk -d -o WWN "$DRIVE" 2>/dev/null | awk 'NR==2{print $1}')"
[[ -z "${SERIAL:-}" ]] && SERIAL="${WWN:-UNKNOWN}"
[[ -z "${SERIAL:-}" ]] && SERIAL="UNKNOWN"

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
BASE="drive_${SERIAL}_${TS}"
SMART_TXT="${WORKDIR}/${BASE}_smart.txt"
SMART_SUMMARY_TXT="${WORKDIR}/${BASE}_smart_summary.txt"
BADBLOCKS_TXT="${WORKDIR}/${BASE}_badblocks.txt"
REPORT_TXT="${WORKDIR}/${BASE}_report.txt"
REPORT_PDF="${WORKDIR}/${BASE}_report.pdf"
NWIPE_TTYLOG="${WORKDIR}/${BASE}_nwipe.typescript"

echo "===== DRIVE PREP START $(timestamp) ====="
echo "Session log: $SESSION_LOG"
echo; echo ">>> DRIVE DETAILS (lsblk) <<<"
lsblk -d -o NAME,SIZE,MODEL,SERIAL,WWN "$DRIVE"
echo; echo "Model: ${MODEL:-unknown}"; echo "Serial: ${SERIAL:-unknown}"; echo "WWN: ${WWN:-unknown}"

echo
echo "!!! DANGEROUS: This will IRREVERSIBLY WIPE $DRIVE !!!"
read -r -p "Type EXACTLY 'YES' to proceed: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 1; }

# Unmount again (belt & suspenders)
mapfile -t PARTS < <(lsblk -ln -o NAME,MOUNTPOINT "$DRIVE" | awk '$2!=""{print $1}')
if (( ${#PARTS[@]} )); then
  echo "Unmounting mounted partitions..."
  for p in "${PARTS[@]}"; do mp="$(lsblk -ln -o MOUNTPOINT "/dev/$p" | awk 'NR==1{print $1}')"
    [[ -n "$mp" ]] && umount -v "/dev/$p"
  done
fi
pause_here "Identification & unmount done. Continue?"

# ====== STEP 4: Environment & hardware snapshots =============================
phase "Environment snapshot"
echo "Kernel: $(uname -a)"
echo "smartctl: $(smartctl -V | head -1)"
echo "nwipe: $({ nwipe --version 2>&1 || true; } | head -1)"
echo "nvme-cli: $({ nvme version 2>&1 || true; } | head -1)"

# Robust badblocks version reporting (Ubuntu 25.04 safe)
get_bb_ver() {
  local v
  v="$({ badblocks 2>&1 || true; } | sed -n 's/^badblocks \([0-9][0-9.]*\).*/badblocks \1/p' | head -n1)"
  [[ -n "$v" ]] || v="$({ /sbin/badblocks 2>&1 || true; } | sed -n 's/^badblocks \([0-9][0-9.]*\).*/badblocks \1/p' | head -n1)"
  [[ -n "$v" ]] || v="$({ dpkg-query -W -f='e2fsprogs ${Version}\n' e2fsprogs 2>/dev/null || true; } \
                      | sed -n 's/^e2fsprogs \([0-9][0-9.:~+-]*\).*/badblocks (e2fsprogs \1)/p' | head -n1)"
  [[ -n "$v" ]] || v="$({ /sbin/fsck.ext4 -V 2>&1 || true; } \
                      | sed -n 's/^e2fsprogs \([0-9][0-9.]*\).*/badblocks (e2fsprogs \1)/p' | head -n1)"
  [[ -n "$v" ]] || v="badblocks (version unknown)"
  echo "$v"
}
echo "badblocks: $(get_bb_ver)"

pause_here "Review environment snapshot above. Continue?"

# ====== STEP 4b: Hardware snapshot (quiet, target-focused) ====================
phase "Hardware snapshot"

echo "# target device (no deps)"
lsblk -ndo NAME,TYPE,SIZE,MODEL,SERIAL,WWN,TRAN,RM "$DRIVE" || true

echo; echo "# smartctl --scan-open (for reference)"
smartctl --scan-open 2>/dev/null || true

echo; echo "# usb topology (optional)"
lsusb -t 2>/dev/null || true

echo; echo "# kernel messages (filtered, last 80; hide audit/apparmor) - captured to log only"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -k --since='-5 min' --no-pager \
    | grep -Ei 'usb|scsi|nvme|sd[a-z]|ata|blk|queue' \
    | grep -Eiv 'apparmor|audit' \
    | tail -n 80 >> "$SESSION_LOG" 2>&1 || true
else
  dmesg \
    | grep -Ei 'usb|scsi|nvme|sd[a-z]|ata|blk|queue' \
    | grep -Eiv 'apparmor|audit' \
    | tail -n 80 >> "$SESSION_LOG" 2>&1 || true
fi
echo "[dmesg output captured to session log]"

pause_here "Check hardware snapshot (lsblk/smartctl/lsusb). Continue?"

# ====== STEP 5: SMART auto-detect & initial snapshot =========================
smart_guess() {
  local dev="$1" dtype
  dtype="$(smartctl --scan-open | awk -v d="$dev" '$1==d {print $3; exit}')"
  if [[ -n "$dtype" ]]; then echo "smartctl -d $dtype"; return 0; fi
  for t in "sat,auto" "sat,12" "sat,16" "sat" "scsi"; do
    smartctl -d "$t" -i "$dev" >/dev/null 2>&1 && { echo "smartctl -d $t"; return 0; }
  done
  return 1
}
SMARTCTL_BIN="$(smart_guess "$DRIVE" || true)"
SMART_AVAILABLE=1

if [[ -n "${SMARTCTL_BIN:-}" ]]; then
  _IDINFO="$({ $SMARTCTL_BIN -i "$DRIVE" 2>/dev/null || true; })"
  [[ -z "${MODEL:-}"  ]] && MODEL="$(awk -F: '/Device Model|Model Number/ {sub(/^[ \t]+/, "", $2); print $2; exit}' <<<"$_IDINFO")"
  [[ -z "${SERIAL:-}" ]] && SERIAL="$(awk -F: '/Serial Number/ {gsub(/[ \t]/,"",$2); print $2; exit}' <<<"$_IDINFO")"
fi

phase "SMART initial snapshot"
if [[ -n "$SMARTCTL_BIN" ]]; then
  if $SMARTCTL_BIN -a "$DRIVE" | tee "$SMART_TXT" >/dev/null 2>&1; then
    SMART_AVAILABLE=0
  else
    echo "SMART attributes unavailable (likely USB bridge limitation)." | tee "$SMART_TXT"
  fi
else
  echo "SMART attributes unavailable (detection failed)." | tee "$SMART_TXT"
fi
if (( SMART_AVAILABLE != 0 )); then
  {
    echo
    echo "*** NOTE ***"
    echo "SMART attributes unavailable (likely USB bridge limitation)."
    echo "Drive identity verified (model/serial). Wipe and surface scan results included below."
  } >> "$SMART_TXT"
fi
pause_here "Review SMART initial snapshot. Continue to WIPE PHASE?"

# ====== STEP 6: Wipe phase (nvme format or nwipe) ============================
if [[ "$DRY_RUN" = "1" ]]; then
  phase "WIPE PHASE (DRY RUN)"
  WIPE_METHOD="DRY RUN (simulated nwipe DoD Short, verify last)"
  WIPE_LOG_APPLIES=1
  {
    echo "=== DRY RUN: Simulating nwipe DoD Short (verify last) on $DRIVE ==="
    echo "[00:00] pass 1/3 ..."; sleep 1
    echo "[00:01] pass 2/3 ..."; sleep 1
    echo "[00:02] pass 3/3 ..."; sleep 1
    echo "[00:03] verify ...";  sleep 1
    if [[ "$DRY_NWIPE_FAIL" = "1" ]]; then echo "Nwipe failed (simulated)."; else echo "Nwipe successfully completed. See summary table for details."; fi
  } |& tee "$NWIPE_TTYLOG"
  if [[ "$DRY_NWIPE_FAIL" = "1" ]]; then NWIPE_RC=1; else NWIPE_RC=0; fi
else
  phase "WIPE PHASE START"
  if [[ "$DRIVE" =~ ^/dev/nvme ]]; then
    echo "Device node is NVMe. Trying secure format first"
    if run "nvme secure format" nvme format -s1 "$DRIVE"; then
      echo "nvme secure format succeeded."
      NWIPE_RC=0
      WIPE_METHOD="NVMe format -s1 (secure erase)"
      WIPE_LOG_APPLIES=0
    else
      if [[ "${ALLOW_NWIPE_ON_NVME:-0}" = "1" ]]; then
        echo "nvme format failed; ALLOW_NWIPE_ON_NVME=1 set, attempting nwipe on NVMe."
        { env -i PATH="$PATH" TERM="${TERM:-xterm}" HOME="$WORKDIR" XDG_CONFIG_HOME="$WORKDIR" XDG_CACHE_HOME="$WORKDIR" \
            nwipe --autonuke --method=dodshort --verify=last --nowait "$DRIVE" |& tee "$NWIPE_TTYLOG"; }
        NWIPE_RC=${PIPESTATUS[0]}; echo "NWIPE exit code: $NWIPE_RC"
        WIPE_METHOD="nwipe DoD short (NVMe fallback)"
        WIPE_LOG_APPLIES=1
      else
        echo "FATAL: nvme format failed; not attempting nwipe on NVMe (set ALLOW_NWIPE_ON_NVME=1 to allow)."
        exit 1
      fi
    fi
  else
    echo "USB non-NVMe device. Using nwipe (DoD Short, verify=last) with progress UI."
    { env -i PATH="$PATH" TERM="${TERM:-xterm}" HOME="$WORKDIR" XDG_CONFIG_HOME="$WORKDIR" XDG_CACHE_HOME="$WORKDIR" \
        nwipe --autonuke --method=dodshort --verify=last --nowait "$DRIVE" |& tee "$NWIPE_TTYLOG"; }
    NWIPE_RC=${PIPESTATUS[0]}; echo "NWIPE exit code: $NWIPE_RC"
    WIPE_METHOD="nwipe DoD short (verify last)"
    WIPE_LOG_APPLIES=1
  fi
fi
pause_here "Wipe phase complete (NWIPE_RC=${NWIPE_RC:-?}). Continue to wipefs?"

# ====== STEP 7: Clear filesystem signatures ==================================
WIPEFS_RC=0
if [[ "$DRY_RUN" = "1" ]]; then
  phase "wipefs -a (DRY RUN)"; WIPEFS_STATUS="skipped (DRY_RUN)"
else
  phase "wipefs -a (clear signatures)"
  WIPEFS_STATUS="unknown"
  if wipefs -a "$DRIVE" 2>&1 | tee -a "$SESSION_LOG"; then 
    WIPEFS_STATUS="cleared"
  else 
    WIPEFS_STATUS="failed"
    WIPEFS_RC=1
  fi
fi
pause_here "wipefs status: ${WIPEFS_STATUS}. Continue to badblocks scan?"

# ====== STEP 8: Sector test (read-only badblocks) =============================
bb_summary_line=""
bb_count=0
if [[ "$DRY_RUN" = "1" ]]; then
  phase "BADBLOCKS SECTOR TEST (DRY RUN)"
  if [[ "$DRY_BADBLOCKS_FAIL" = "1" ]]; then
    bb_summary_line="Pass completed, 1 bad blocks found. (1/0/1 errors)"
    echo "$bb_summary_line" | tee "$BADBLOCKS_TXT"; BB_RC=1
  else
    bb_summary_line="Pass completed, 0 bad blocks found. (0/0/0 errors)"
    echo "$bb_summary_line" | tee "$BADBLOCKS_TXT"; BB_RC=0
  fi
  echo "badblocks exit code: $BB_RC"
else
  phase "BADBLOCKS SECTOR TEST (read-only)"
  set +e
  stdbuf -oL -eL badblocks -sv "$DRIVE" 2>&1 | tee "$BADBLOCKS_TXT"
  BB_RC=${PIPESTATUS[0]}
  set -e
  echo "badblocks exit code: $BB_RC"

  # Extract a clean summary line and count
  bb_summary_line="$(grep -E 'Pass completed|[0-9]+ bad blocks found|\([0-9]+/[0-9]+/[0-9]+ errors\)' "$BADBLOCKS_TXT" | tail -n1 || true)"
  bb_count="$(echo "$bb_summary_line" | sed -n 's/.*\([0-9][0-9]*\) bad blocks found.*/\1/p')"
  bb_count="${bb_count:-0}"
fi
pause_here "Badblocks finished (BB_RC=${BB_RC:-?}). Continue to SMART self-test?"

# ====== STEP 9: SMART short test (if available) ===============================
if (( SMART_AVAILABLE == 0 )); then
  phase "SMART short self-test"
  if [[ "$DRY_RUN" = "1" ]]; then
    echo "DRY RUN: Skipping actual SMART self-test."
  else
    $SMARTCTL_BIN -t short "$DRIVE" || true
    echo "Waiting ~2 minutes for SMART short test to complete..."; sleep 120 || true
    phase "SMART post-short snapshot"; $SMARTCTL_BIN -a "$DRIVE" >> "$SMART_TXT" || true
  fi
else
  phase "SMART self-test skipped"
fi
pause_here "SMART self-test phase done. Continue to summary/report?"

# ====== STEP 10: Build concise SMART summary (buyer-facing) ==================
smart_raw() {  # usage: smart_raw <ID> <NAME_WITH_UNDERSCORES>
  awk -v id="$1" -v name="$2" '$1==id && $2==name {print $NF}' "$SMART_TXT" | tail -n1
}
build_smart_summary() {
  if (( SMART_AVAILABLE != 0 )) || [[ ! -s "$SMART_TXT" ]]; then
    { echo "SMART Health Summary"; echo "Status: SMART unavailable (USB bridge limitation or not detected)."; } > "$SMART_SUMMARY_TXT"; return
  }
  local HEALTH POH PWR_CYC REALLOC PENDING UNCORR CRC TEMP ERRLOG SELFTEST
  HEALTH="$(
    awk -F': ' '
      /SMART overall-health self-assessment test result:/ {print $2; f=1}
      /SMART Health Status:/ {print $2; f=1}
    END{ if(!f) print "" }
  ' "$SMART_TXT" | sed 's/[[:space:]]*$//'
  )"
  POH="$(smart_raw 9 Power_On_Hours)"
  PWR_CYC="$(smart_raw 12 Power_Cycle_Count)"
  REALLOC="$(smart_raw 5 Reallocated_Sector_Ct)"
  PENDING="$(smart_raw 197 Current_Pending_Sector)"
  UNCORR="$(smart_raw 198 Offline_Uncorrectable)"
  CRC="$(smart_raw 199 UDMA_CRC_Error_Count)"
  TEMP="$(smart_raw 194 Temperature_Celsius)"
  if grep -q 'No Errors Logged' "$SMART_TXT"; then ERRLOG="No errors logged"; else ERRLOG="Errors present (see raw SMART log)"; fi
  if awk '/^# /{print}' "$SMART_TXT" | grep -qv 'Completed without error'; then
    SELFTEST="Mixed/failed entries (see raw SMART log)"
  elif awk '/^# /{print}' "$SMART_TXT" | grep -q 'Completed without error'; then
    SELFTEST="All recorded self-tests completed without error"
  else
    SELFTEST="No recorded self-tests"
  fi
  {
    echo "SMART Health Summary  ${MODEL:-unknown} (${SERIAL:-unknown})"
    echo "Overall Health: ${HEALTH:-UNKNOWN}"
    echo "Power-On Hours: ${POH:-UNKNOWN}"
    echo "Power Cycles:   ${PWR_CYC:-UNKNOWN}"
    echo "Reallocated Sectors:     ${REALLOC:-UNKNOWN}"
    echo "Current Pending Sectors: ${PENDING:-UNKNOWN}"
    echo "Offline Uncorrectable:   ${UNCORR:-UNKNOWN}"
    echo "UDMA CRC Errors:         ${CRC:-UNKNOWN}"
    [[ -n "${TEMP:-}" ]] && echo "Temperature: ${TEMP} C"
    echo "SMART Error Log: ${ERRLOG}"
    echo "Self-Tests: ${SELFTEST}"
  } > "$SMART_SUMMARY_TXT"
}
build_smart_summary

# ====== STEP 11: Kernel messages after run ===================================
phase "Kernel messages after run - captured to log only"
dmesg | tail -n 120 | \
  grep -Ev 'apparmor=\"DENIED\".*operation=\"capable\"|capname=\"(dac_read_search|dac_override)\"' \
  >> "$SESSION_LOG" 2>&1 || true
echo "[Final dmesg output captured to session log]"
pause_here "Final dmesg tail captured. Continue to assemble report?"

# ====== STEP 12: Assemble final report (clean PDF; filenames only) ===========
phase "Assemble final report"
{
  echo "===== DRIVE PREP SUMMARY ====="
  echo "Timestamp (UTC): $TS"
  echo "Device: $DRIVE"
  echo "Model:  ${MODEL:-unknown}"
  echo "Serial: ${SERIAL:-unknown}"
  echo "WWN:    ${WWN:-unknown}"
  echo
  echo "---- SUMMARY OF OPERATIONS ----"
  if [[ ${NWIPE_RC:-1} -eq 0 ]]; then
    echo "Wipe: ${WIPE_METHOD:-unknown} (completed)"
  else
    echo "Wipe: ${WIPE_METHOD:-unknown} (check logs, rc=${NWIPE_RC:-?})"
  fi
  echo "Badblocks: ${bb_summary_line:-Completed (see log)}"
  echo "wipefs: ${WIPEFS_STATUS}"
  echo
  echo "===== DETAILS ====="
  echo
  echo "---- SMART (Buyer-Facing Summary) ----"
  if [[ -s "$SMART_SUMMARY_TXT" ]]; then 
    cat "$SMART_SUMMARY_TXT"
  else 
    echo "SMART summary not available."
  fi
  echo
  echo "---- ARTIFACT FILENAMES ----"
  echo "Session log:      $(basename "$SESSION_LOG")"
  if [[ "$WIPE_LOG_APPLIES" = "1" && -f "$NWIPE_TTYLOG" ]]; then
    echo "Nwipe transcript: $(basename "$NWIPE_TTYLOG")"
  else
    echo "Nwipe transcript: (not applicable for NVMe format or not captured)"
  fi
  echo "Badblocks log:    $(basename "$BADBLOCKS_TXT")"
  echo "SMART raw log:    $(basename "$SMART_TXT")"
  echo "SMART summary:    $(basename "$SMART_SUMMARY_TXT")"
} > "$REPORT_TXT"

if command -v enscript >/dev/null 2>&1 && command -v ps2pdf >/dev/null 2>&1; then
  enscript -B -b "Drive Prep Report" -p - "$REPORT_TXT" 2>/dev/null | ps2pdf - "$REPORT_PDF" 2>/dev/null || {
    echo "Warning: PDF generation failed, text report available at: $REPORT_TXT"
  }
else
  echo "Warning: enscript or ps2pdf not found, skipping PDF generation"
fi
pause_here "Report generated: $(basename "$REPORT_PDF"). Continue to ownership & classification?"

# ====== STEP 13: Fix ownership if run via sudo ===============================
if [[ -n "${SUDO_USER:-}" ]]; then
  echo "Fixing ownership for $SUDO_USER..."
  chown -R "$SUDO_USER":"$SUDO_USER" "$WORKDIR"
fi

echo
echo "Text report: $(basename "$REPORT_TXT")"
if [[ -f "$REPORT_PDF" ]]; then
  echo "PDF report:  $(basename "$REPORT_PDF")"
fi
echo "Session log: $(basename "$SESSION_LOG")"
[[ -f "$NWIPE_TTYLOG" ]] && echo "Nwipe progress transcript: $(basename "$NWIPE_TTYLOG")"
echo "Quick grep for errors:"
echo "  grep -iE 'error|fail|unsupported|ioctl' '$(basename "$SESSION_LOG")' || true"

pause_here "Ownership and summaries printed. Continue to classify & move logs?"

# ====== STEP 14: Final classification (SUCCESS/FAILED) =======================
RESULT_DIR="$WORKDIR"
FINAL_DIR=""
if [[ ${NWIPE_RC:-0} -ne 0 || ${BB_RC:-0} -ne 0 || ${WIPEFS_RC:-0} -ne 0 ]]; then
  # Explain badblocks return codes for clarity
  case "${BB_RC:-0}" in
    1) echo "Badblocks found ${bb_count} bad sector(s).";;
    2) echo "Badblocks usage error (rc=2) - check badblocks install/args.";;
    4) echo "Badblocks device I/O error (rc=4) - check cabling/enclosure.";;
  esac
  FINAL_DIR="$WORKDIR/FAILED";  echo "[RESULT] Drive failed wipe or badblocks scan. Moving logs to FAILED."
else
  FINAL_DIR="$WORKDIR/SUCCESS"; echo "[RESULT] Drive passed wipe and badblocks scan. Moving logs to SUCCESS."
fi
mkdir -p "$FINAL_DIR"
mv "${WORKDIR}/${BASE}"* "$FINAL_DIR/" 2>/dev/null || true
mv "$SESSION_LOG" "$FINAL_DIR/" 2>/dev/null || true

pause_here "Files moved to: $FINAL_DIR. Press Enter to finish."
echo; echo "Done. Reports in: $FINAL_DIR"
