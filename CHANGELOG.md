## Changelog

### v0.3.1 - 2026-05-10
- Added `disktools.sh` top-level dispatcher: interactive menu plus direct subcommand invocation (`detect`/`archive`/`rescue`/`wipe`/`status`).
- Added `scripts/setup_local_samba_share.sh` and `disktools.sh setup-share` for the no-NAS path: local archive output under `/srv/legacy-media`, shared over SMB/CIFS with Samba.
- Audit pass on existing scripts:
  - Fixed syntax error in `wipedriveforsale.sh` (line 370 `}` → `fi`) that prevented the script from parsing at all.
  - Fixed `USER_HOME` resolution in `wipedriveforsale.sh` to use `getent passwd` instead of hard-coded `/home/$SUDO_USER`.
  - Relaxed `interactive_data_rescue.sh` tool checks: HFS helpers (`hmount`/`hcopy`/`fsck.hfs`) are now optional and checked at point of use, not as preflight blockers.
  - Replaced `archive_media.sh` `trap '…' RETURN` (which leaked across all subsequent function returns) with explicit cleanup helper.
  - Stopped auto-folding dvdisaster/safecopy output back into the ddrescue mapfile — those tools zero-fill unreadable sectors, which would corrupt the primary image. Fallback artifacts are now kept separate and listed in the report.
  - Added mount-fstype mapping (parted `fat32`→`vfat`, `ntfs`→`ntfs-3g`) so partition-offset mounts work for FAT/NTFS.
  - Added empty-config-value validation and post-imaging "is the image non-empty?" check.
  - Replaced `sleep 120` after SMART short test with a poll based on the drive's reported polling time.
  - Corrected install docs to use Ubuntu's `genisoimage` package for `isoinfo`, and documented the difference between CIFS client mounts (`cifs-utils`) and serving a local SMB/CIFS share (`samba`).

### v0.3.0 - 2026-05-10
- Added archive workflow: `scripts/detect_media.sh` (auto-detection of Zip/CD/DVD/HDD with TSV/JSON output) and `scripts/archive_media.sh` (interactive orchestrator: NAS mount, staged ddrescue, optional dvdisaster/cdparanoia/safecopy fallbacks, rsync to NAS, per-case report).
- Added `config/archive.conf.example` with CIFS/NFS/already-mounted/local transport options.
- Added `docs/media_detection.md`, `docs/nas_setup.md`, `docs/recovery_strategies.md`.
- Added Claude Code project scaffolding: `CLAUDE.md`, `.claude/settings.json`, slash commands (`/detect`, `/archive`, `/status`).
- Updated `README.md` and `INSTALL.md` to cover both workflows.

### v0.2.0 - 2025-11-25
- Cleaned and clarified documentation and safety guidance.
- Completed legal, install, contributing, and security docs for public release.
- Fixed script prompts/defaults for safer USB-only operation and log handling.

### v0.1.0 - 2025-11-25
- Initial release of Disk Tools (wipe + data rescue utilities).
