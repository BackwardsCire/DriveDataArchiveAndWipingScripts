# How to Use Disktools

Step-by-step walkthroughs for the four things you'd actually do with these scripts. Read [README.md](../README.md) first for the 30-second summary; come here when you're about to do a real run.

- [Before you start](#before-you-start)
- [First-time setup](#first-time-setup)
- [The interactive menu](#the-interactive-menu)
- [Walkthrough: archive a Zip disk](#walkthrough-archive-a-zip-disk)
- [Walkthrough: archive a CD or DVD](#walkthrough-archive-a-cd-or-dvd)
- [Walkthrough: archive an old hard drive](#walkthrough-archive-an-old-hard-drive)
- [Walkthrough: wipe a drive for resale](#walkthrough-wipe-a-drive-for-resale)
- [Reading the report](#reading-the-report)
- [What to do when bad sectors remain](#what-to-do-when-bad-sectors-remain)
- [Resuming and re-imaging — the mapfile is your friend](#resuming-and-re-imaging--the-mapfile-is-your-friend)
- [Troubleshooting](#troubleshooting)

---

## Before you start

You need:

- **An Ubuntu 25.04+ box** with the dependencies from [INSTALL.md](../INSTALL.md). The two key packages are `gddrescue` (provides `ddrescue` + `ddrescuelog`) and `rsync`.
- **Sudo access** on that box. Imaging block devices, mounting loop devices, and running `nwipe` all need root.
- **A reachable NAS** for the archive workflow. SMB/CIFS, NFS, or any path under an already-mounted filesystem works. See [docs/nas_setup.md](nas_setup.md).
- **Local scratch space.** ddrescue writes the image to disk first, then rsyncs to the NAS. Plan on **2× the source size** under `SCRATCH_DIR` (image + mapfile + possible fallback-tool artifacts). A 700 MB CD is fine; a 250 MB Zip disk is trivial; a 1 TB old HDD needs serious local headroom.
- **A USB enclosure or dock** for whatever you're plugging in. For Zip drives this is usually a USB Zip drive itself; for IDE hard drives, a USB-to-IDE/SATA adapter; for CDs/DVDs, a USB optical drive.
- **`tmux`** if the imaging might take more than a few minutes. ddrescue on a flaky Zip can run for hours — you do not want a closed SSH session to take that with it.

Things to know:

- Source media is read-only-as-far-as-possible until imaging finishes. Mount the *image*, not the original.
- The scripts respect `SUDO_USER` so artifacts land under the invoking user's home, not root's, even when you run with `sudo`.
- Everything destructive (wipes, the deep-scrape decision, deleting scratch images) is gated behind a y/N or "type the word" prompt.

---

## First-time setup

```bash
# 1. Clone or copy the repo somewhere convenient
cd ~/projects
git clone <repo-url> DriveDataArchiveAndWipingScripts
cd DriveDataArchiveAndWipingScripts

# 2. Install dependencies (full list in INSTALL.md)
sudo apt update
sudo apt install -y \
  gddrescue parted rsync file util-linux coreutils tmux \
  hfsprogs hfsutils ntfs-3g exfatprogs genisoimage \
  dvdisaster cdparanoia safecopy
# Pick the NAS transport you'll use:
sudo apt install -y cifs-utils         # for SMB/CIFS NASes
# or:
sudo apt install -y nfs-common         # for NFS exports

# No NAS? Install Samba and share this box locally:
sudo apt install -y samba smbclient cifs-utils acl
sudo ./disktools.sh setup-share

# 3. Configure the NAS destination
cp config/archive.conf.example config/archive.conf
$EDITOR config/archive.conf
# Set at minimum: NAS_DEST, NAS_TRANSPORT, and (for cifs/nfs) the
# share/export + credentials paths. See docs/nas_setup.md.
# If you used setup-share instead of a NAS, set:
./disktools.sh dest local /srv/legacy-media

# 4. Sanity-check the install
./disktools.sh detect       # read-only scan, no sudo needed
```

A successful detect run prints a table like:

```
DEVICE       KIND     SIZE       MODEL                  TRAN     FS/STATE
------       ----     ----       -----                  ----     --------
/dev/sr0     optical  650MB      Plextor PX-712UF       usb      iso9660
/dev/sdc     zip      94MB       USB Zip 100            usb      vfat
```

If you see your device with a sensible FS/STATE, you're ready. If FS/STATE says `unreadable` or `no medium`, see [Troubleshooting](#troubleshooting).

### Pre-flight tip: try a dry run

Before your first real run, exercise the orchestrator without touching anything:

```bash
sudo DRY_RUN=1 ./disktools.sh archive /dev/sdc
```

DRY_RUN skips ddrescue, mount, and rsync but exercises everything else (config load, NAS check, prompts, report generation). If this fails, fix it before kicking off a real 6-hour Zip-disk recovery.

### Low-interaction mode

For batch-style archiving, pass the source device and set `AUTO=1`. The defaults come from `config/archive.conf`; `AUTO_DEEP_SCRAPE=1` runs deep-scrape automatically if bad sectors remain, and `DDRESCUE_PASS_TIMEOUT=3h` caps each ddrescue pass.

```bash
sudo AUTO=1 MTYPE_OVERRIDE=cd NAME_OVERRIDE=test-cd-01 ./disktools.sh archive /dev/sr0
```

If a pass times out, the ddrescue mapfile is kept. You can rerun the same kind of command later and ddrescue will continue from the mapfile state instead of starting from scratch.

---

## The interactive menu

```bash
./disktools.sh                    # menu
# or, pick a subcommand directly:
./disktools.sh detect             # no sudo
sudo ./disktools.sh archive       # ddrescue + rsync
sudo ./disktools.sh rescue        # legacy HFS-aware helper
sudo ./disktools.sh wipe /dev/X   # destructive
./disktools.sh status             # recent reports
```

The menu shows:

```
1) Detect attached media          (read-only scan, no sudo needed)
2) Archive media to NAS           (ddrescue + multi-pass + rsync)
3) Rescue from a specific device  (older interactive helper, HFS-aware)
4) Wipe a drive for resale        (DESTRUCTIVE — irreversible)
5) Show recent session reports
q) Quit
```

For a long imaging or wipe job, wrap the whole menu in tmux so a disconnect doesn't kill it:

```bash
sudo tmux new -s disktools './disktools.sh'
# detach: Ctrl-b then d
# reattach: tmux attach -t disktools
```

You pick once per run; the chosen action exec()s into its script. To start another action, re-run `./disktools.sh`.

---

## Walkthrough: archive a Zip disk

Zip 100/250 disks are the canonical "click of death" media. Image them while they still read at all.

1. **Plug in the Zip drive.** USB Zip drives appear as `/dev/sd?` (e.g. `/dev/sdc`). Insert a disk.

2. **Confirm it's seen.**
   ```bash
   ./disktools.sh detect
   ```
   You want a row with `kind=zip` (or `usb-hdd` if the brand/size heuristic missed) and a non-zero size. If the medium is unreadable, the script will still happily image whatever it can — bad sectors are the whole point.

3. **Start an archive in tmux.**
   ```bash
   sudo tmux new -s archive
   sudo ./disktools.sh archive /dev/sdc
   ```

4. **Answer the prompts.**
   - Media type: `zip` (default, since detect_media tagged it).
   - Short case name: something like `wedding-photos-1998`. Letters, digits, `._-` only.
   - "Plan looks right?" — review, hit Enter.

5. **Watch ddrescue do its thing.** You'll see two passes: fast (`-n`) then retry (`-d -r4`). On a healthy Zip, both finish in 5–15 minutes. On a flaky one, the retry pass can run for hours.

6. **Deep-scrape prompt.** If the retry pass left bad sectors, you'll be asked whether to run a reverse-direction deep-scrape with high retries. **Say yes** unless you're in a hurry — it costs time, never data.

7. **Fallback tools (if still bad).** If `FALLBACK_TOOLS` is set in `archive.conf` and bad sectors remain after deep-scrape, the configured tools run (typically `safecopy` for Zip). These produce **separate** artifacts next to the main image — they do not overwrite it.

8. **Mount + rsync.** The script auto-detects the filesystem (usually FAT on PC-formatted Zips, HFS on Mac-formatted) and rsyncs to `NAS_DEST/zip-<name>-<timestamp>/`.

9. **Report.** Look in `report.txt` inside the case directory. Verify the destination listing matches what you expected. If "bad bytes remaining" is 0, you got everything. If not, see [What to do when bad sectors remain](#what-to-do-when-bad-sectors-remain).

10. **Cleanup prompt.** Decide whether to keep the local `.img` and mapfile. **Keep them if there are bad sectors** — you might re-image with a different drive later. Delete them only after you're sure the case is closed.

11. **Repeat for the next disk.** Re-run `./disktools.sh archive` for the next one.

### What if the Zip drive can't read the disk at all?

If the kernel reports persistent I/O errors (`dmesg | tail`), try:

- A second Zip drive. Zip drives age too; sometimes the disk is fine and the drive is the problem.
- Cleaning the heads (commercial Zip head-cleaning disks exist).
- A different USB port — bus-power flakiness mimics media failure.
- Letting the disk warm up (or cool down) for 30 minutes before retrying. Bearing failures are temperature-sensitive.

If a different drive reads sectors this drive can't, run ddrescue against the same mapfile (see [the mapfile is your friend](#resuming-and-re-imaging--the-mapfile-is-your-friend)). Newly-readable sectors get filled in.

---

## Walkthrough: archive a CD or DVD

Pressed CDs are usually fine; CD-Rs and DVD-Rs degrade as their dye layer fades. Outer tracks (written last) fail first.

1. **Insert the disc** into a USB optical drive. It appears as `/dev/sr0` (or `/dev/sr1` for the second drive).

2. **Confirm it spins up.**
   ```bash
   ./disktools.sh detect
   ```
   You want a row with `kind=optical` and a sensible size. If size is 0 or FS/STATE is `no medium`, the drive doesn't think a disc is loaded — eject and reinsert, or try a different drive.

3. **Start the archive.**
   ```bash
   sudo tmux new -s archive
   sudo ./disktools.sh archive /dev/sr0
   ```
   Pick `cd` for the media type (or `dvd`). The script uses `ddrescue -b 2048` for optical-sized sectors automatically.

   For the least interactive path:
   ```bash
   sudo AUTO=1 MTYPE_OVERRIDE=cd NAME_OVERRIDE=my-cd-name ./disktools.sh archive /dev/sr0
   ```

4. **Let it run.** Pressed discs read in a few minutes. Failing CD-Rs can take all night.

5. **dvdisaster fallback.** For optical media with bad sectors, `dvdisaster --read` runs as a fallback. Its output goes to `<image>.dvdisaster.iso` next to the main image. **Don't blindly merge it back into the main image** — dvdisaster zero-fills unreadable sectors, so the merge would overwrite good data with zeros. The two files are kept separate; compare them manually if you need to.

6. **Mount detect.** The script tries ISO9660, then UDF (for DVDs), then partitioned offsets. If your CD has an HFS partition (old Mac CDs), try the legacy rescue helper instead — it has more nuanced HFS handling.

7. **Check the result.** Some CDs are mixed-mode (audio + data) — `cdparanoia` produces per-track WAVs in `<image>-audio/` if configured. The data session ends up in the case directory.

### CD recovery tips

- Slow the drive down for marginal discs: `setcd -x 4 /dev/sr0` before running. Quieter laser pickup, fewer retries needed.
- Try multiple drives. The variance between two USB optical drives reading the same scratched disc is huge.
- For pressed CDs with visible scratches, a careful polish can dramatically change what's readable. Image-before-and-after to see the difference.

---

## Walkthrough: archive an old hard drive

Same flow as a Zip disk, but bigger and slower.

1. **Connect the drive** via a USB-to-SATA or USB-to-IDE adapter. Powered docks are more reliable than bus-powered for 3.5" drives.

2. **Detect.**
   ```bash
   ./disktools.sh detect
   ```
   The drive shows up as `hdd` (or `usb-hdd`). Note the size — you'll need at least that much free space under `SCRATCH_DIR`.

3. **Image.**
   ```bash
   sudo tmux new -s archive
   sudo ./disktools.sh archive /dev/sdc
   ```
   Pick `hdd` for media type. For a 500 GB drive, expect the fast pass alone to take 2–6 hours over USB 3.

4. **Mount, rsync.** The script tries common Linux/Windows filesystems first, then partition-offset mounts. If the drive is GPT-partitioned with multiple volumes, only the first usable partition is mounted automatically — for multi-partition rescues, you may want to image-then-mount each partition by hand (see [docs/data_rescue.md](data_rescue.md) for the legacy interactive helper).

5. **Heat management.** If the drive is failing and warming up, take breaks. Most consumer drives perform worse above 50°C. `smartctl -A /dev/sdc | grep -i temp` will tell you.

---

## Walkthrough: wipe a drive for resale

This is destructive and irreversible. Use only on drives you intend to sell or recycle.

1. **Disconnect everything you care about.** Seriously. Belt and suspenders.

2. **Connect the target drive** via USB. The wipe tool defaults to USB-only operation; non-USB targets require `ALLOW_NONUSB=1`.

3. **Find the device path.**
   ```bash
   ./disktools.sh detect
   # or
   lsblk -o NAME,TRAN,SIZE,MODEL,SERIAL,MOUNTPOINT
   ```
   Be absolutely sure of the path. `/dev/sda` is usually your system disk — the wipe tool refuses to touch it, but better safe.

4. **Start under tmux.**
   ```bash
   sudo tmux new -s wipe
   sudo ./disktools.sh wipe /dev/sdb
   ```

5. **Type `YES`** at the confirmation. Anything else aborts.

6. **Let it run.** Phases: nwipe DoD short (3 passes + verify) → wipefs (clears filesystem signatures) → badblocks read-only surface scan → SMART short self-test → report assembly.

7. **Read the report.** It's auto-classified into `SUCCESS/` or `FAILED/` under `~/drive_reports/`. The PDF is the buyer-facing summary; the text + raw logs are for your records.

### When the wipe says FAILED

`FAILED/` means one of:
- nwipe couldn't complete a pass (drive errored out during write).
- badblocks found bad sectors (drive has reallocated/uncorrectable issues).
- wipefs couldn't clear signatures.

A drive in `FAILED/` is not safe to sell as functional. The report tells you which step failed; the raw logs (`*_smart.txt`, `*_badblocks.txt`, `session_*.log`) tell you why.

### Pause-between-phases mode

```bash
sudo PAUSE=1 ./disktools.sh wipe /dev/sdb
```

`PAUSE=1` stops between major phases so you can inspect each before continuing. Useful when learning the tool or debugging a quirky drive.

---

## Reading the report

After an archive run, the per-case directory on the NAS contains:

```
NAS_DEST/zip-wedding-1998-20260510T143022Z/
├── report.txt                  # this run's summary
├── <recovered file tree>       # rsync'd from the mounted image
└── (if no mountable FS) <basename>.img   # raw image as a fallback
```

`report.txt` includes:

- **Imaging exit codes.** 0 = clean. Non-zero with bad bytes > 0 = ddrescue couldn't recover everything but kept what it could.
- **Bad bytes remaining.** Number of unrecoverable bytes per the mapfile. 0 is the goal.
- **Mapfile summary** (from `ddrescuelog -t`). Shows percentages: rescued, errored, non-tried.
- **Fallback artifacts** (if any). Paths to dvdisaster/safecopy/cdparanoia output. **Listed for your awareness; not merged automatically.**
- **Destination listing.** First 50 entries in the case directory. Spot-check this against what you expected.

The mapfile itself (`<basename>.img.map`) stays in `SCRATCH_DIR` unless you opted to delete it. **Keep mapfiles for any case with bad bytes > 0** — they let you resume with a different drive later.

A copy of `report.txt` also lands in `~/drive_reports/<basename>-report.txt` so you have a local index even if the NAS goes offline.

---

## What to do when bad sectors remain

Three things to try, in escalating order:

### 1. Re-image with a different drive against the same mapfile

This is the single highest-leverage trick.

```bash
sudo ddrescue -d -r8 /dev/sdc /your/SCRATCH_DIR/zip-wedding-1998-<ts>.img \
                                 /your/SCRATCH_DIR/zip-wedding-1998-<ts>.img.map
```

The mapfile records which sectors are still bad. ddrescue skips good ones and only retries the bad ones. Whatever sectors the new drive reads cleanly get filled in. Repeat for as many drives as you have access to.

### 2. Inspect the fallback-tool artifacts

If `archive_media.sh` ran dvdisaster or safecopy, you have separate images like `<base>.dvdisaster.iso` or `<base>.safecopy.img`. Compare them against the main image:

```bash
# Where do they differ?
cmp -l "$base.img" "$base.dvdisaster.iso" | head -20

# Look at a specific sector in each:
dd if="$base.img"             bs=2048 skip=N count=1 | xxd | head
dd if="$base.dvdisaster.iso"  bs=2048 skip=N count=1 | xxd | head
```

If dvdisaster has *non-zero* data where ddrescue has zeros (or vice versa), the fallback got something the primary didn't. Cherry-pick by hand using `dd conv=notrunc bs=2048 skip=N seek=N count=1`.

### 3. Mount what you have and accept the loss

Sometimes the data is just gone. Mount the image read-only, copy what mounts cleanly, and move on:

```bash
sudo mount -o loop,ro "$base.img" /mnt/recovery
# Check what's intact:
sudo find /mnt/recovery -type f -exec wc -c {} \; > /tmp/sizes.txt
# Look for zero-byte files — often a symptom of bad sectors backing the file:
sudo find /mnt/recovery -type f -size 0
sudo umount /mnt/recovery
```

Bad sectors that fall inside an unallocated region of the filesystem cause no visible file damage. Bad sectors inside a file produce zero-filled regions or read errors when you try to open it.

---

## Resuming and re-imaging — the mapfile is your friend

A ddrescue mapfile is a tiny text file that records, byte-range by byte-range, what state each region of the image is in: good / bad / non-tried / etc. **Keep mapfiles for any case that isn't fully recovered.**

You can:

- **Resume** an interrupted ddrescue run. Just rerun the same command; ddrescue picks up where it left off.
- **Switch drives** mid-recovery. Rerun ddrescue with the same mapfile against a different source device — the new drive's reads fill in the old drive's gaps.
- **Switch tools** mid-recovery. The mapfile is ddrescue-specific, but you can hand a recovered partial image to other tools and merge results manually (see step 2 above).

To re-attack a case days or weeks later:

```bash
# Replug the source, then:
sudo ddrescue -d -r16 /dev/sdc /your/scratch/.../zip-name-<ts>.img \
                                /your/scratch/.../zip-name-<ts>.img.map
ddrescuelog -t /your/scratch/.../zip-name-<ts>.img.map
```

The `ddrescuelog -t` line tells you the current state. If `rescued:` is at 100% and `bad-sector:` is 0, you're done — remount the image, rerun rsync to the NAS case directory.

---

## Troubleshooting

| Symptom | Likely cause | What to try |
|---------|--------------|-------------|
| `detect_media.sh` shows `no medium` for an optical drive that has a disc in it | Drive cached the previous (ejected) disc's state | Eject and reinsert; unplug the USB drive briefly |
| `detect_media.sh` shows `unreadable` | First sectors are bad, or no read permission, or the drive is failing | Try imaging anyway — ddrescue handles unreadable initial sectors |
| `archive_media.sh` aborts with "No config at:" | First-time setup not done | `cp config/archive.conf.example config/archive.conf` and edit |
| `archive_media.sh` aborts with "NAS_DEST … is not under any mounted filesystem" | `NAS_TRANSPORT=mounted` but the share isn't actually mounted | `mountpoint -q /mnt/nas` to verify; check `/etc/fstab` and `mount -a` |
| `archive_media.sh` aborts with "ddrescue produced an empty image" | ddrescue couldn't open the device at all (often: device disappeared between scan and run, or the device path is wrong) | Re-run `./disktools.sh detect`; check `dmesg | tail` for USB disconnects |
| Mount step fails with "wrong fs type" | Filesystem isn't in the auto-probe list, or the image needs partition-offset mounting | Try the legacy `scripts/interactive_data_rescue.sh` for HFS+ / APM cases; or mount manually with `sudo mount -o loop,ro,offset=N -t TYPE image /mnt/...` |
| rsync prints `EPERM`/`EINVAL` warnings | CIFS mount doesn't support xattrs/ACLs | Harmless; files copy, only metadata is skipped. Edit `copy_to_nas` to drop `-AX` flags if it bothers you |
| Wipe tool fails preflight: `Missing required command(s)` | Wipe-only packages not installed | `sudo apt install -y smartmontools e2fsprogs nwipe enscript ghostscript nvme-cli` |
| Wipe tool: `FATAL: $DRIVE not detected as USB/removable` | Internal SATA/NVMe drive | If intentional: `sudo ALLOW_NONUSB=1 ./disktools.sh wipe /dev/sdX`. If unintentional: stop, you're about to wipe the wrong thing |
| `ddrescue: I/O error` repeated rapidly in the log | Cable/enclosure problem, not media problem | Different USB port, different cable, different enclosure |
| Long imaging stalls forever on one sector | Drive is hard-hung on that read | `Ctrl-C`, then resume — ddrescue marks that sector bad and moves on |
| `disktools.sh archive` says "This action … needs root" | You forgot `sudo` | Re-run with sudo (or, inside tmux: `sudo ./disktools.sh archive`) |

For anything not on this list, check `~/drive_reports/archive_*.log` — the session log captures every command and its output.
