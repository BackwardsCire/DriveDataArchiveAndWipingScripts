# Media Detection (`scripts/detect_media.sh`)

Lists every source candidate the kernel currently knows about — disks (`type=disk`) and optical drives (`type=rom`) — and excludes the system disk. The system disk is identified by walking up from the `/` mountpoint via `lsblk -no PKNAME`.

## What it shows

| Column | Source | Notes |
|--------|--------|-------|
| DEVICE | `lsblk` | e.g. `/dev/sr0`, `/dev/sdc` |
| KIND   | classifier | `optical` / `zip` / `usb-hdd` / `hdd` / `other` |
| SIZE   | `lsblk -b` + `numfmt --to=iec` | Reported by the kernel; may be 0 if no medium |
| MODEL  | `lsblk` | Vendor model string |
| TRAN   | `lsblk` | Transport (`usb`, `ata`, `sata`, etc.) |
| FS/STATE | probe | One of: `iso9660`, `vfat`, `hfs`, `ntfs`, `ext`, `unknown`, `unreadable`, `no medium` |

## How "kind" is decided

1. `type=rom` → `optical`.
2. Vendor or model contains `iomega` / `zip` / `jaz` → `zip`.
3. Removable device whose size is approximately one of the Iomega media capacities (~100 / ~250 / ~750 MB) → `zip` (covers third-party USB Zip drives that don't advertise the brand).
4. `tran=usb` and not matched above → `usb-hdd`.
5. Anything else with `type=disk` → `hdd`.

This is heuristic. A USB SD card reader showing a 250 MB card would falsely classify as `zip`; review the model column before kicking off an archive.

## Output modes

```bash
scripts/detect_media.sh           # human-readable table (default)
scripts/detect_media.sh --tsv     # tab-separated, one row per device, header line
scripts/detect_media.sh --json    # JSON array of objects
```

The TSV form is what `archive_media.sh` consumes to pick a default media type.

## "no medium" vs "unreadable"

- **`no medium`** — the drive is present but reports zero sectors. Insert a disk.
- **`unreadable`** — the drive reports a size but `file -s` cannot read the first sectors. Either the medium is severely damaged, the drive is failing, or you don't have read permission. Imaging may still recover something, but expect a long ddrescue run.

## Empty optical drive quirk

USB optical drives sometimes cache the previous disc's sector count even after eject, so `SIZE` may be non-zero with `FS/STATE=unreadable`. Ejecting and reinserting (or unplugging the drive briefly) usually clears this. A genuine fresh insertion will show a sensible filesystem like `iso9660`.
