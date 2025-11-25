# Disk Tools - Drive Wipe and Data Rescue (Ubuntu 25.04+)

Two operator-focused Bash utilities for securely wiping drives for resale and safely rescuing data from failing media. Both scripts are designed for unattended runs inside `tmux` with clear logging and PDF-ready outputs.

---

## What's Included

- **wipedriveforsale.sh** - Securely wipes drives (DoD short with verify), clears filesystem signatures, runs a read-only surface scan, gathers SMART data, and produces buyer/audit-friendly reports.
- **interactive_data_rescue.sh** - Guides you through imaging and recovering data from damaged or legacy drives using `ddrescue`, read-only mounts, and optional file copy via `rsync`.

---

## Requirements

Built and tested on **Ubuntu 25.04+**.

**Core (wipe + rescue)**
```bash
sudo apt update
sudo apt install -y smartmontools e2fsprogs nwipe enscript ghostscript nvme-cli \
  util-linux usbutils coreutils tmux gdisk parted gawk sed grep
```

**Optional (rescue / imaging)**
```bash
sudo apt install -y gddrescue pv ntfs-3g exfatprogs hfsprogs hfsutils zip unzip
```

---

## Install

```bash
git clone https://github.com/your-org/disk-tools.git disk-tools
cd disk-tools
chmod +x scripts/*.sh
```

---

## Quick Start

### Wipe a drive for resale
```bash
sudo tmux new -s wipe
sudo ./scripts/wipedriveforsale.sh /dev/sdX   # example: /dev/sdb
```
- Step through phases: `sudo PAUSE=1 ./scripts/wipedriveforsale.sh /dev/sdX`

### Rescue data from a failing drive
```bash
sudo tmux new -s rescue
sudo ./scripts/interactive_data_rescue.sh
```
- The script prompts for source device, media type, and case name.

### Working inside tmux
```
Ctrl+b then d   # detach
tmux ls         # list sessions
tmux attach -t wipe   # reattach
```

---

## Outputs and Logging

- All artifacts go to `~/drive_reports/` under the invoking user's home (even when run with sudo). No usernames need to be hardcoded.
- **Wipe reports:** Text + PDF summaries, SMART raw and summary logs, `nwipe` transcript, `badblocks` output, and the session log. Runs are auto-sorted into `SUCCESS/` or `FAILED/`.
- **Rescue sessions:** Imaging logs, ddrescue map/log, recovery notes, and command transcript saved to `~/drive_reports/rescue_<timestamp>.log`.

---

## Safety Checks (wipe tool)

- Refuses to run on the system disk or mounted partitions.
- Defaults to USB/removable-only operation; set `ALLOW_NONUSB=1` to override.
- Destructive steps require explicit confirmation unless `DRY_RUN=1`.

---

## Configuration Flags (wipe tool)

| Variable | Purpose |
|----------|---------|
| `DEBUG=1` | Shell tracing into the session log. |
| `PAUSE=1` | Pause between major phases. |
| `DRY_RUN=1` | Simulate destructive actions for testing. |
| `ALLOW_NONUSB=1` | Allow non-USB/non-removable targets (defaults to USB-only). |
| `DRY_NWIPE_FAIL=1`, `DRY_BADBLOCKS_FAIL=1` | Simulate failures while in dry-run. |
| `INCLUDE_NWIPE_TTY=1` | Embed `nwipe` progress output in reports. |

---

## Troubleshooting

- **Ghostscript/enscript missing:** Install `enscript` and `ghostscript`; PDF generation is skipped if absent.
- **Badblocks "device busy":** Ensure all partitions on the target are unmounted (`sudo lsof /dev/sdX` can help).
- **SMART unavailable over USB:** Some bridges mask SMART; the report will note when SMART cannot be read.
- **Slow runs:** Use `tmux` and let the script finish; logs stream to `~/drive_reports/`.

---

## Repository Layout

- `scripts/wipedriveforsale.sh` - wipe + verify + report
- `scripts/interactive_data_rescue.sh` - imaging and recovery helper
- `docs/wipe_drive.md` - detailed wipe instructions
- `docs/data_rescue.md` - detailed rescue workflow
- `CHANGELOG.md`, `LICENSE`, `INSTALL.md`, `CONTRIBUTING.md`, `SECURITY.md`

---

## License

MIT License. See `LICENSE`.
