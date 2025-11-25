# wipedriveforsale.sh - Secure Wipe and Verification Guide

Completely prepares a drive for resale or decommissioning with logging and PDF-friendly reporting.

---

## What It Does

- DoD short wipe via `nwipe` (3 passes + blanking + verify)
- Clears filesystem signatures with `wipefs -a`
- Read-only surface scan using `badblocks -sv`
- SMART capture (raw + summarized buyer-facing view)
- Generates text + PDF reports and sorts results into `SUCCESS/` or `FAILED/`
- Defaults to USB/removable-only operation

---

## Run It

```bash
sudo ./scripts/wipedriveforsale.sh /dev/sdX   # example: /dev/sdb
```

Helpful variations:
```bash
sudo PAUSE=1 ./scripts/wipedriveforsale.sh /dev/sdX   # step through phases
sudo DRY_RUN=1 ./scripts/wipedriveforsale.sh /dev/sdX # simulate without touching the disk
sudo ALLOW_NONUSB=1 ./scripts/wipedriveforsale.sh /dev/sdX # permit non-USB targets
```

Use `tmux` to keep the session alive during long wipes:
```
sudo tmux new -s wipe
sudo ./scripts/wipedriveforsale.sh /dev/sdX
Ctrl+b then d   # detach
tmux attach -t wipe
```

## Find the target device

Before running, confirm the correct drive path:
```bash
lsblk -o NAME,TRAN,SIZE,MODEL,SERIAL,MOUNTPOINT
```
- Look for the removable/USB disk you intend to wipe (commonly `/dev/sdb`, `/dev/sdc`, etc.).
- Avoid anything with active mountpoints or that matches your OS drive.

---

## Outputs

All artifacts go to `~/drive_reports/` under the invoking user's home.

- `*_smart.txt`  raw SMART dump
- `*_smart_summary.txt`  buyer-facing SMART summary (health, hours, reallocated, pending, uncorrectable, CRC, temp)
- `*_badblocks.txt`  surface scan log
- `*_report.txt` / `*_report.pdf`  formatted summary with filenames only (no absolute paths or usernames)
- `session_*.log`  full command transcript
- Files are moved into `SUCCESS/` or `FAILED/` after completion

---

## Safety and Checks

- Refuses to run on the system disk or on mounted partitions.
- Default `ALLOW_NONUSB=0` blocks non-removable media unless explicitly overridden.
- Prompts for confirmation before destructive actions unless `DRY_RUN=1`.
- SMART is best-effort; some USB bridges hide SMART data (noted in the report).

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| SMART data unavailable | Try a direct SATA connection; some USB enclosures block SMART. |
| Ghostscript/enscript missing | Install `ghostscript` and `enscript`; text reports are still written. |
| "device busy" | Unmount all partitions on the target (`sudo umount /dev/sdX*`), or use `sudo lsof /dev/sdX` to find blockers. |
| PDF not produced | Check disk space and ensure `enscript`/`ps2pdf` are installed. Text report is always created. |

---

## Notes

- Always confirm the correct target with `lsblk` before proceeding.
- For the safest posture, keep `ALLOW_NONUSB=0` and attach drives via USB docks or write blockers.
- Keep reports with the drive if selling or transferring custody.

