---
description: Walk the user through archiving one piece of media to the NAS.
argument-hint: "[device path, e.g. /dev/sr0 or /dev/sdc]"
---

Help the user archive media at `$ARGUMENTS` (or, if empty, run `/detect` first and ask them to pick).

Before running anything destructive of time:
1. Confirm `config/archive.conf` exists. If only `config/archive.conf.example` is present, walk the user through creating their own copy and filling in the NAS destination.
2. Confirm the NAS path is reachable (`mountpoint -q` or by attempting the configured mount per `docs/nas_setup.md`). Don't auto-mount without telling the user what you're about to mount.
3. Confirm the chosen device is **not** the system disk and is **not** currently mounted as something the user is using. Refuse if either is true.

Then launch `sudo tmux new -s archive-<short-name> 'sudo ./scripts/archive_media.sh <device>'` so the imaging survives terminal disconnects. If the user is already inside tmux, skip the wrapper.

After the script returns, read the per-case report in `~/drive_reports/` and summarize: bytes recovered vs. total, bad sectors remaining, which recovery passes ran, and what landed on the NAS.
