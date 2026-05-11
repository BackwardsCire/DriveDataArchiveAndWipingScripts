# Recovery Strategies for Aging Media

Old Zip disks, CD-Rs, and pressed CDs that have been sitting in a closet for 20–30 years tend to fail in characteristic ways:

- **Zip 100/250 ("click of death")** — bearing/heads degrade, reads succeed inconsistently. Re-imaging across multiple sessions can recover sectors that one pass missed.
- **CD-R / DVD-R** — dye layer fades. Outer tracks (which were written last) fail first. Slowing the drive and trying multiple lasers/drives helps.
- **Pressed CDs** — usually fine; bit rot exists but is rarer than dye-layer loss. Scratches are the main enemy.
- **Old hard drives** — bearing failure or weak heads. Cool the drive, image with retries, then archive the image and stop reading from the original.

`archive_media.sh` runs a stages strategy. Each stage only runs if the previous left bad sectors behind.

## Stage 1: ddrescue fast pass (`-n`)

```bash
ddrescue -n SOURCE IMAGE MAPFILE
```

Skips slow areas, grabs the easy sectors first. This is the most important pass — you get most of the data quickly, and the mapfile records what's left for later stages.

## Stage 2: ddrescue retry (`-d -r${RETRIES}`)

```bash
ddrescue -d -r4 SOURCE IMAGE MAPFILE
```

Direct disc access (`-d`, where supported), retry each unread sector up to N times. `RETRIES=4` is a sane default; bump it for media you really care about.

## Stage 3 (conditional): deep-scrape (`-d -R -r${DEEP_RETRIES}`)

Triggered automatically when stage 2 left bad sectors. Reverses the read direction (`-R`), which can help when the drive's head can read a track better in one direction than the other, and bumps retries to `DEEP_RETRIES=16` by default.

By default `AUTO_DEEP_SCRAPE=1` in `archive.conf`, so the archive workflow runs this pass without prompting. Set it to an empty string if you want the old prompt back.

## Watchdog: `DDRESCUE_PASS_TIMEOUT`

Each ddrescue pass is wrapped in `timeout` when `DDRESCUE_PASS_TIMEOUT` is set. The default example config uses:

```bash
DDRESCUE_PASS_TIMEOUT="3h"
```

Timeouts are per pass, not per whole disc. If a pass times out, the mapfile and partial image are kept and the workflow continues with the data recovered so far. You can rerun ddrescue later against the same image/mapfile to resume.

## Stage 4 (conditional): media-specific fallback tools

Configured via `FALLBACK_TOOLS` in `archive.conf`. These run only when bad sectors remain after the ddrescue passes.

Fallback artifacts are kept separate from the primary ddrescue image. That is intentional: tools such as `dvdisaster` and `safecopy` may zero-fill unreadable areas in their own output. Blindly merging those files back into the ddrescue image can overwrite good sectors with zeros.

### `dvdisaster` (optical only)

```bash
dvdisaster -d /dev/sr0 -i image.dvdisaster.iso --read
```

dvdisaster has its own bad-sector handling and can sometimes coax sectors out that ddrescue gives up on. Its output is listed in the final report as a separate artifact to compare manually.

### `cdparanoia` (audio CDs only)

```bash
cdparanoia -B -d /dev/sr0
```

For mixed-mode or audio CDs. Writes one WAV per track into a per-case `*-audio/` directory under `SCRATCH_DIR`. ddrescue is the wrong tool for CDDA — audio CDs lack a real filesystem and cdparanoia has the jitter/correction logic.

### `safecopy` (any block device)

```bash
safecopy --stage1 SOURCE OUT
safecopy --stage2 SOURCE OUT
safecopy --stage3 SOURCE OUT
```

Three stages of progressively more aggressive read patterns. Slow but thorough; use as a last resort. Its image and bad-block list are kept beside the main image for manual inspection.

## When to give up

- ddrescue mapfile shows the same `bad-sector:` byte count after two full passes plus deep-scrape — the data on those sectors is physically gone.
- The drive starts producing read errors on sectors it previously read fine — the drive is failing. Stop, swap drives, image again from a fresh drive.
- I/O errors that hit the kernel log (`dmesg | grep -i 'I/O error'`) accumulate fast — usually means a bus/cable problem, not the medium. Try a different USB port, cable, or enclosure.

## Multiple drives, multiple sessions

Same mapfile, different drives: rerun `archive_media.sh` against the same case name (or manually run `ddrescue -d -r4 OTHER_DRIVE IMAGE MAPFILE`). The mapfile makes ddrescue resume — already-read sectors are skipped, only the gaps are retried, and any that the new drive happens to read get filled in. This is the single biggest recovery trick available; keep mapfiles around even after the case "completes."

## Verifying the recovered tree

After the rsync step, the NAS case directory is the source of truth. Spot-check:

- `find $CASE_DIR -size 0` — zero-byte files often mean a sector was bad and the filesystem returned an empty file rather than a read error. Worth inspecting.
- `find $CASE_DIR -name '*.iso' -exec isoinfo -d -i {} \;` — for archived CD images, sanity-check ISO descriptors.
- Hash-stamp the tree with `find $CASE_DIR -type f -exec sha256sum {} +` so you can detect drift if the NAS itself has problems later.
