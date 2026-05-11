# DriveDataArchiveAndWipingScripts (Ubuntu 25.04+)

Two related Bash workflows for working with old/legacy storage on a Linux box:

1. **Archive aging media to local or NAS storage** — auto-detect Zip disks, optical drives, and legacy hard drives; image with `ddrescue` using a multi-pass / multi-tool recovery strategy; mount the image and rsync recovered files to your configured archive destination.
2. **Securely wipe drives for resale** — DoD-short wipe with `nwipe`, surface scan with `badblocks`, SMART capture, and a buyer-friendly PDF report.

The two workflows share helpers (logging conventions, sudo-aware home-directory handling) but are otherwise independent — you can use either without the other.

No NAS is required if you do not want one: write archives to a local path and use the included Samba setup helper to publish that path as a LAN SMB/CIFS share.

---

## What's Included

### Archive workflow
- **`scripts/detect_media.sh`** — enumerates source candidates (Zip / optical / USB / IDE) with kind classification, even when no medium is inserted. `--tsv` and `--json` output for scripting.
- **`scripts/archive_media.sh`** — interactive orchestrator. Reads `config/archive.conf`, ensures the archive destination is ready, picks (or accepts) a device, runs ddrescue in stages with optional fallback tools (`dvdisaster`, `cdparanoia`, `safecopy`), mounts the image read-only, and rsyncs to storage.
- **`scripts/setup_local_samba_share.sh`** — optional helper for the no-NAS case. Installs/configures Samba so the local archive directory is shared over SMB/CIFS.
- **`config/archive.conf.example`** — template for archive destination, mount type (local/CIFS/NFS/already-mounted), retry counts, fallback chain.

### Wipe workflow (unchanged from earlier releases)
- **`scripts/wipedriveforsale.sh`** — wipe + verify + report.
- **`scripts/interactive_data_rescue.sh`** — older single-device rescue helper, kept for cases the new orchestrator doesn't handle (custom HFS partition layouts, etc.).

---

## Where to look

- **First time using this?** Read [docs/USAGE.md](docs/USAGE.md) — practical step-by-step walkthroughs for archiving Zip disks, CDs/DVDs, and old hard drives, plus the wipe workflow and what to do when ddrescue leaves bad sectors.
- **Installing?** [INSTALL.md](INSTALL.md).
- **NAS configuration?** [docs/nas_setup.md](docs/nas_setup.md).
- **Curious about the multi-pass recovery logic?** [docs/recovery_strategies.md](docs/recovery_strategies.md).

## Quick Start

A single entry point — [disktools.sh](disktools.sh) — drives the daily workflows plus one-time local share setup:

```bash
./disktools.sh             # interactive menu
./disktools.sh detect      # read-only scan (no sudo needed)
sudo ./disktools.sh archive [/dev/sdX]
sudo AUTO=1 MTYPE_OVERRIDE=cd NAME_OVERRIDE=test-cd-01 ./disktools.sh archive /dev/sr0
sudo ./disktools.sh wipe /dev/sdX
sudo ./disktools.sh rescue
./disktools.sh status      # recent ~/drive_reports entries
sudo ./disktools.sh setup-share  # optional: local SMB/CIFS share when you do not use a NAS
./disktools.sh dest local /srv/legacy-media
```

The menu picks once per run, then execs into the chosen script. For long imaging or wipe runs, start inside tmux:

```bash
sudo tmux new -s disktools './disktools.sh'
```

### First-time archive setup

```bash
# 1. install dependencies (see INSTALL.md for the full list)
sudo apt update && sudo apt install -y gddrescue parted rsync \
  hfsprogs hfsutils dvdisaster safecopy cdparanoia file util-linux genisoimage tmux

# 2. configure your archive destination
cp config/archive.conf.example config/archive.conf
$EDITOR config/archive.conf

# 3. confirm what's hooked up, then start the menu
./disktools.sh detect
sudo tmux new -s disktools './disktools.sh'
```

If you want local sharing instead of a NAS:

```bash
sudo ./disktools.sh setup-share
# then in config/archive.conf:
# NAS_TRANSPORT="none"
# NAS_DEST="/srv/legacy-media"
```

### Wipe workflow

```bash
sudo tmux new -s wipe 'sudo ./disktools.sh wipe /dev/sdX'   # USB-only by default
```

See [docs/wipe_drive.md](docs/wipe_drive.md) for the full wipe walkthrough.

---

## Workflow at a glance (archive)

```
detect_media.sh
      │
      ▼
archive_media.sh /dev/X
      │
      ├─► verify archive destination reachable (mount or check)
      ├─► ddrescue fast pass            (-n)
      ├─► ddrescue retry pass           (-d -r4)
      ├─► [if bad sectors] deep-scrape  (-d -R -r16)
      ├─► [optional] dvdisaster / cdparanoia / safecopy fallbacks
      ├─► mount image read-only, rsync → archive case directory
      └─► write report.txt locally + with the archived files
```

Each step is gated and can be skipped via `DRY_RUN=1`. See [docs/recovery_strategies.md](docs/recovery_strategies.md) for the why behind each stage.

---

## Repository layout

```
.
├── disktools.sh                    # top-level dispatcher + interactive menu
├── CLAUDE.md                       # project context for Claude Code
├── README.md
├── INSTALL.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE
├── .claude/
│   ├── settings.json
│   └── commands/                   # /detect, /archive, /status
├── config/
│   └── archive.conf.example
├── docs/
│   ├── USAGE.md                    # **step-by-step walkthroughs — start here**
│   ├── data_rescue.md              # original interactive_data_rescue guide
│   ├── wipe_drive.md
│   ├── media_detection.md          # detect_media.sh
│   ├── nas_setup.md                # NAS transports & fstab patterns
│   └── recovery_strategies.md      # multi-pass / multi-tool reasoning
└── scripts/
    ├── detect_media.sh
    ├── archive_media.sh
    ├── setup_local_samba_share.sh
    ├── interactive_data_rescue.sh
    └── wipedriveforsale.sh
```

---

## Outputs

All artifacts go under `~/drive_reports/` of the invoking user (sudo-safe). A copy of the per-case report also lands in the archive case directory so the report travels with the data.

Per archive case directory: `<media-type>-<short-name>-<UTC-timestamp>/` with:

- the recovered file tree,
- `report.txt` (sources, ddrescue exit codes, bad-byte tally, mapfile summary, destination listing),
- and — if the image couldn't be mounted — the raw `.img` itself.

---

## Safety

- Read-only on the source until imaging is complete; the image is the canonical source for everything downstream.
- Refuses to touch the system disk; warns and prompts before unmounting partitions on the source.
- `DRY_RUN=1` skips every destructive/expensive command but exercises the flow end-to-end.
- Wipe tool defaults to USB-only operation; override only with `ALLOW_NONUSB=1`.

---

## License

MIT. See [LICENSE](LICENSE).
