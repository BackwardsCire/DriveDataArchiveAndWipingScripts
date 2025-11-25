#! /usr/bin/env bash
# interactive_data_rescue.sh
# Imaging + optional deep-scrape (auto-prompt if bad sectors) + mount (ISO/HFS/APM) + copy + ownership fix.

set -Eeuo pipefail
umask 077

# Resolve invoking user + home even under sudo
OWNER="${SUDO_USER:-$USER}"
OWNER_HOME="$(getent passwd "${OWNER}" | cut -d: -f6)"
[[ -z "${OWNER_HOME}" ]] && OWNER_HOME="$(eval echo "~${OWNER}")"

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
REPORT_ROOT="${OWNER_HOME}/drive_reports"
SESSION_LOG="${REPORT_ROOT}/rescue_${TS}.log"
RECOVERY_DIR="${OWNER_HOME}/recovery"
OUTPUT_ROOT="${OWNER_HOME}/RecoveredData"
MNT_DIR="${OWNER_HOME}/mnt"
RETRIES=4           # standard retry count
DEEP_RETRIES=10     # deep-scrape retry count
IMAGING_RC=0
DEEP_RC=0
COPY_RC=0

require() { command -v "$1" &>/dev/null || { echo "Missing: $1"; MISSING=1; }; }
MISSING=0
require ddrescue      || true   # pkg: gddrescue
require ddrescuelog   || true   # comes with gddrescue; used to read mapfile
require parted        || true
require file          || true
require awk           || true
require grep          || true
require sed           || true
require mount         || true
require lsblk         || true
require hmount        || true   # pkg: hfsutils
require hcopy         || true
require humount       || true
require fsck.hfs      || true   # pkg: hfsprogs
require rsync         || true
if [[ "${MISSING}" == "1" ]]; then
  echo
  echo "Install deps on Ubuntu:"
  echo "  sudo apt update && sudo apt install -y gddrescue parted hfsprogs hfsutils file rsync"
  exit 1
fi

sudo mkdir -p "${REPORT_ROOT}" "${RECOVERY_DIR}" "${OUTPUT_ROOT}" "${MNT_DIR}"
sudo chown -R "${OWNER}:${OWNER}" "${REPORT_ROOT}" "${RECOVERY_DIR}" "${OUTPUT_ROOT}" "${MNT_DIR}"

exec > >(tee -a "$SESSION_LOG") 2>&1
echo "==> Session log: ${SESSION_LOG}"

pause() { read -rp "==> $*  Press Enter to continue..."; }
ftype() { file -b "$1" | tr 'A-Z' 'a-z'; }
fix_ownership() { sudo chown -R "${OWNER}:${OWNER}" "$1" || true; }

echo "==> Connected block devices:"
lsblk
pause "Review lsblk above."

read -rp "Enter the SOURCE device path (e.g., /dev/sdc for ZIP/HDD, /dev/sr0 for CD): " SRC
[[ -b "${SRC}" ]] || { echo "Not a block device: ${SRC}"; exit 1; }

read -rp "Media type [cd|zip|hdd]: " MTYPE
MTYPE="$(echo "${MTYPE}" | tr 'A-Z' 'a-z')"
case "${MTYPE}" in cd|zip|hdd) ;; *) echo "Invalid media type."; exit 1 ;; esac

read -rp "Short name for this image (no spaces recommended): " NAME
BASE="${MTYPE}-${NAME}"
IMAGE="${RECOVERY_DIR}/${BASE}.img"
DDRESCUE_LOG="${IMAGE}.log"
DEST="${OUTPUT_ROOT}/${BASE}"
sudo mkdir -p "${DEST}"
fix_ownership "${DEST}"

# ------------------- ddrescue imaging -------------------
# CDs need 2048-byte sectors. Others can use default (512).
if [[ "${MTYPE}" == "cd" ]]; then
  BSARG="-b2048"
else
  BSARG=""
fi

echo "==> Imaging ${SRC} -> ${IMAGE}"
set +e
sudo ddrescue ${BSARG} -f -n "${SRC}" "${IMAGE}" "${DDRESCUE_LOG}"
IMAGING_RC=$?
if (( IMAGING_RC != 0 )); then
  echo "!! ddrescue fast pass failed (rc=${IMAGING_RC}). Check ${DDRESCUE_LOG} for details."
  exit "${IMAGING_RC}"
fi
sudo ddrescue ${BSARG} -d -r${RETRIES} "${SRC}" "${IMAGE}" "${DDRESCUE_LOG}"
IMAGING_RC=$?
set -e
if (( IMAGING_RC != 0 )); then
  echo "!! ddrescue retry pass failed (rc=${IMAGING_RC}). Check ${DDRESCUE_LOG} for details."
  exit "${IMAGING_RC}"
fi
echo "==> ddrescue finished. Log: ${DDRESCUE_LOG} (rc=${IMAGING_RC})"

# Auto-detect bad sectors from the mapfile; prompt deep-scrape if needed.
BAD_BYTES_RAW="$(ddrescuelog -t "${DDRESCUE_LOG}" 2>/dev/null | awk '/bad-sector:/ {print $2, $3}')"
# Normalize to integer bytes (e.g., "1024 B" -> 1024, "0 B" -> 0)
BAD_BYTES="$(ddrescuelog -t "${DDRESCUE_LOG}" 2>/dev/null | awk '/bad-sector:/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
[[ -z "${BAD_BYTES}" ]] && BAD_BYTES=0
echo "==> Mapfile summary: bad sectors reported: ${BAD_BYTES_RAW:-unknown}"

if (( BAD_BYTES > 0 )); then
  read -rp "Bad sectors detected. Run deep-scrape (reverse direction, extra retries)? [y/N]: " DEEP
  DEEP=${DEEP:-N}
  if [[ "${DEEP}" =~ ^[Yy]$ ]]; then
    echo "==> Deep-scrape: reverse direction with extra retries."
    set +e
    sudo ddrescue ${BSARG} -d -R -r${DEEP_RETRIES} "${SRC}" "${IMAGE}" "${DDRESCUE_LOG}"
    DEEP_RC=$?
    set -e
    echo "==> Deep-scrape pass finished (rc=${DEEP_RC})."
    if (( DEEP_RC != 0 )); then
      echo "!! Deep-scrape reported errors; review ${DDRESCUE_LOG}."
    fi
  fi
else
  echo "==> No bad sectors reported; skipping deep-scrape."
fi

pause "Verify the ddrescue output looked good."

# ------------------- Mount & copy -------------------
FT=$(ftype "${IMAGE}")
echo "==> file(1): ${FT}"

copy_from_mount() {
  local mnt="$1" dest="$2"
  echo "==> Copying files to ${dest}"
  set +e
  rsync -a --info=progress2 "${mnt}/" "${dest}/"
  local RS=$?
  set -e
  fix_ownership "${dest}"
  if [[ $RS -ne 0 ]]; then
    echo "   rsync had issues (likely filename encoding). Will try hfsutils fallback if possible."
    COPY_RC=1
    return 1
  fi
  echo "==> Copy complete."
  COPY_RC=0
  return 0
}

if echo "${FT}" | grep -q "iso 9660"; then
  echo "==> Detected ISO9660. Mounting read-only."
  sudo mount -o loop,ro -t iso9660 "${IMAGE}" "${MNT_DIR}"
  copy_from_mount "${MNT_DIR}" "${DEST}" || true
  sudo umount "${MNT_DIR}"

else
  mounted_raw=""
  for fstype in hfs hfsplus; do
    if sudo mount -o loop,ro -t "${fstype}" "${IMAGE}" "${MNT_DIR}" 2>/dev/null; then
      echo "==> Mounted raw ${fstype} at offset 0."
      mounted_raw="yes"
      if ! copy_from_mount "${MNT_DIR}" "${DEST}"; then
        echo "   Attempting hfsutils fallback copy."
        if hmount "${IMAGE}" 1 2>/dev/null; then
          hcopy -r : "${DEST}/" || true
          humount || true
          fix_ownership "${DEST}"
        fi
      fi
      sudo umount "${MNT_DIR}"
      break
    fi
  done

  if [[ -z "${mounted_raw}" ]]; then
    echo "==> Probing Apple Partition Map (APM) with parted..."
    PARTED=$(parted -m -s "${IMAGE}" unit B print || true)
    echo "${PARTED}"

    HFS_LINE=$(echo "${PARTED}" | awk -F: 'tolower($6) ~ /^hfs/ {print; exit}')
    if [[ -n "${HFS_LINE}" ]]; then
      START_B=$(echo "${HFS_LINE}" | awk -F: '{print $2}' | sed 's/B$//')
      echo "==> Found HFS partition start at ${START_B} bytes."
      mounted=""
      for fstype in hfs hfsplus; do
        if sudo mount -o "loop,ro,offset=${START_B}" -t "${fstype}" "${IMAGE}" "${MNT_DIR}" 2>/dev/null; then
          echo "==> Mounted ${fstype} at offset ${START_B}."
          mounted="yes"
          if ! copy_from_mount "${MNT_DIR}" "${DEST}"; then
            echo "   Attempting hfsutils fallback copy."
            HFS_INDEX=$(
              echo "${PARTED}" \
                | awk -F: -v tgt="$(echo "${HFS_LINE}" | awk -F: '{print $1}')" '
                   tolower($6) ~ /^hfs/ {i++; if ($1==tgt) {print i; exit}}'
            )
            [[ -z "${HFS_INDEX}" ]] && HFS_INDEX=1
            if hmount "${IMAGE}" "${HFS_INDEX}" 2>/dev/null; then
              hcopy -r : "${DEST}/" || true
              humount || true
              fix_ownership "${DEST}"
            fi
          fi
          sudo umount "${MNT_DIR}"
          break
        fi
      done

      if [[ -z "${mounted}" ]]; then
        echo "!! Kernel mount failed; trying hfsutils only."
        HFS_INDEX=$(
          echo "${PARTED}" \
            | awk -F: 'tolower($6) ~ /^hfs/ {i++; print i; exit}'
        )
        [[ -z "${HFS_INDEX}" ]] && HFS_INDEX=1
        if hmount "${IMAGE}" "${HFS_INDEX}"; then
          hcopy -r : "${DEST}/" || true
          humount || true
          fix_ownership "${DEST}"
        else
          echo "!! hfsutils also failed. Consider extracting the partition and fsck.hfs:"
          echo "  dd if='${IMAGE}' of='${RECOVERY_DIR}/${BASE}-hfs-part.img' bs=1 skip=${START_B}"
          echo "  fsck.hfs -n '${RECOVERY_DIR}/${BASE}-hfs-part.img'"
        fi
      fi
    else
      echo "!! No HFS/HFS+ partition found and not ISO9660."
      echo "   The media may be blank, corrupted, or a different FS."
    fi
  fi
fi

echo
echo "Destination folder: ${DEST}"
sudo ls -la "${DEST}" || true
fix_ownership "${DEST}"
echo
pause "Confirm above looks correct (files copied as expected)."

read -rp "Delete the image and ddrescue log now? [y/N]: " CONF
CONF=${CONF:-N}
if [[ "${CONF}" =~ ^[Yy]$ ]]; then
  sudo rm -f -- "${IMAGE}" "${DDRESCUE_LOG}"
  echo "==> Deleted ${IMAGE} and ${DDRESCUE_LOG}."
else
  echo "==> Keeping image and log in ${RECOVERY_DIR}."
fi

echo
echo "Summary:"
echo "  Session log: ${SESSION_LOG}"
echo "  ddrescue log/map: ${DDRESCUE_LOG} (rc=${IMAGING_RC}, deep-scrape rc=${DEEP_RC})"
echo "  Destination: ${DEST}"
if (( COPY_RC != 0 )); then
  echo "  Copy status: issues encountered (see log and destination contents)."
else
  echo "  Copy status: completed (see destination listing above)."
fi
echo "All done."
