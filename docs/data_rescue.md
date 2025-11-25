# interactive_data_rescue.sh - Imaging and Recovery Guide

Guided tool for safely imaging and extracting data from damaged or legacy drives using `ddrescue`, read-only mounts, and `rsync`.

---

## Goals

- Preserve original media by working read-only where possible.
- Create forensic-friendly images and map files with `ddrescue`.
- Mount images read-only to inspect contents.
- Copy recoverable data to a destination you control, with logging.

---

## Workflow

1) **Identify the source device**
```bash
lsblk -o NAME,SIZE,MODEL,SERIAL
```

2) **Start in tmux**
```bash
sudo tmux new -s rescue
sudo ./scripts/interactive_data_rescue.sh
```

3) **Answer prompts**
- Source device (e.g., `/dev/sdc` or `/dev/sr0`)
- Media type (`cd`, `zip`, or `hdd`) to set sensible block sizes
- Short name for the case (used for filenames)

4) **Imaging**
- `ddrescue` runs a fast pass, then retry passes (`-r`), producing an image and map file.
- Logs are stored with the image for traceability.

5) **Mount the image (read-only)**
```bash
sudo mount -o ro,loop,show_sys_files,streams_interface=windows image.img /mnt/rescue
```

6) **Copy data**
```bash
rsync -aHAX --info=progress2 /mnt/rescue /mnt/destination
```

---

## Optional Tools

```bash
sudo apt install -y gddrescue pv exfatprogs ntfs-3g hfsprogs hfsutils zip unzip
```

---

## Logging and Outputs

- Images and map files are saved under the invoking user's home (no hardcoded usernames).
- A transcript of actions and key commands is written to `~/drive_reports/rescue_<timestamp>.log`.
- Destination folders are created and ownership corrected for the invoking user.

---

## Tips

- Use `pv` if you want to monitor imaging throughput.
- If SMART shows reallocated or pending sectors, image first, then mount/copy from the image.
- Use a powered dock for unstable drives.
- Avoid running `fsck` on original media; work on the image instead.

---

## Example

Recovered files from a degraded HDD: imaged with ddrescue, 2 bad sectors noted, contents mounted read-only, and copied to a clean destination with logs kept for reference.

