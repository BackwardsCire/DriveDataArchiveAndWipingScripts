# DriveDataArchiveAndWipingScripts

Operator-focused Bash toolkit for two related tasks on Ubuntu 25.04+:

1. **Archiving legacy/aging media** (Zip disks, Jaz, CD, DVD, old HDDs) onto a NAS, with graceful sector-error recovery.
2. **Securely wiping drives** for resale or decommissioning, with buyer-friendly reports.

The current focus is **(1)**: there is a large backlog of old Zip disks and CDs to image and copy off before the media degrades further.

## Project layout

- `disktools.sh` — top-level entry point. Interactive menu, or direct subcommand dispatch (`disktools.sh detect|archive|rescue|wipe|status`).
- `scripts/`
  - `detect_media.sh` — enumerate candidate source media (USB Zip, optical, IDE/SATA), even when not mounted; print a parseable summary (human/`--tsv`/`--json`).
  - `archive_media.sh` — interactive orchestrator: detect → pick device → image with multi-pass / multi-tool recovery → mount image → copy to NAS → write a per-case report.
  - `interactive_data_rescue.sh` — older single-device rescue helper (ddrescue + HFS/ISO9660 mount). Kept for special cases (custom HFS partition layouts, etc.).
  - `wipedriveforsale.sh` — secure wipe + verification + buyer report (separate workflow; not part of the archive pipeline).
- `config/archive.conf.example` — template for NAS destination, mount type (CIFS/NFS), credentials path, retry counts.
- `docs/` — per-script guides and strategy notes (`media_detection.md`, `nas_setup.md`, `recovery_strategies.md`, `data_rescue.md`, `wipe_drive.md`).
- `.claude/` — Claude Code config: settings, slash commands.

## Working principles

- **Read-only on source media until imaged.** Always `ddrescue` to a local image first; never mount or `fsck` the original.
- **Image once, recover in stages.** Recovery effort escalates: ddrescue fast pass → ddrescue retry → ddrescue reverse with high retries → media-specific tools (cdparanoia for audio CDs, dvdisaster for data CDs/DVDs, safecopy as last resort).
- **NAS is the destination, not the workspace.** Image scratch space stays on local disk (fast, low-latency for ddrescue). Only the recovered tree and the final report get pushed to the NAS.
- **Per-case directory naming.** `<media-type>-<short-name>-<UTC-timestamp>` so cases don't collide and timestamps survive re-imaging attempts.
- **Run under tmux** for any imaging that may take more than a few minutes — ddrescue on a flaking Zip can run for hours.
- **Sudo-aware paths.** Scripts respect `SUDO_USER`; reports and recovered data land in the invoking user's home / NAS mount, not root's.

## Conventions for changes

- Bash with `set -Eeuo pipefail` and `umask 077`.
- Prefer POSIX utilities and Ubuntu-packaged tools; document any new `apt` package in `INSTALL.md`.
- Don't reduce existing safety guards (USB-only default on the wipe tool, read-only on source, explicit "YES" confirms for destructive ops) without a clear reason.
- New tools that touch a block device must accept `DRY_RUN=1` and skip the destructive/expensive parts.
- Keep logs in `~/drive_reports/` (or the configured NAS report path) and use UTC timestamps in filenames.

## Known gotchas (from the 2026-05-10 audit)

These are now fixed; documenting so they aren't reintroduced.

- **bash `}` vs `fi`**: `wipedriveforsale.sh:370` had a stray `}` that meant the script never parsed. Always `bash -n` after editing.
- **`USER_HOME="/home/$SUDO_USER"` is wrong** for users whose home isn't under `/home`. Use `getent passwd "$SUDO_USER" | cut -d: -f6`.
- **`trap '…' RETURN` inside a function leaks**: bash's RETURN trap fires on every subsequent function return, not just this function's. Use explicit cleanup before each `return` instead.
- **Don't auto-fold dvdisaster/safecopy images back into the ddrescue mapfile.** Those tools zero-fill unreadable sectors in their output. A naive `ddrescue --no-scrape sec.img IMAGE MAPFILE` would overwrite *good* data with zeros. Keep fallback artifacts as separate files; let the operator merge by hand.
- **parted's filesystem names ≠ mount's `-t` names**: parted says `fat32`, mount wants `vfat`; parted says `ntfs`, mount wants `ntfs-3g` for write-capable mounts. Translate before passing to `mount -t`.
- **`IFS=$'\t' read` collapses empty fields** because tab is a whitespace IFS. Use a non-whitespace separator (e.g. `\x1f`) for internal parsing when any field can be empty.
- **`file -bs` writes errors to stdout, not stderr.** `2>/dev/null` won't suppress them; check the exit code.

## Future direction

The interactive archive flow is the starting point. The intended evolution is a non-interactive batch mode (e.g. "loop over every detected Zip disk as it's inserted, image and push to NAS, eject, prompt for next") once the recovery strategy stabilizes. Avoid baking interactive `read -rp` prompts deep into helper functions — keep prompts at the top-level orchestrator so a future `--auto` mode can bypass them. `archive_media.sh` already accepts `AUTO=1` and `DRY_RUN=1` toggles for this purpose.
