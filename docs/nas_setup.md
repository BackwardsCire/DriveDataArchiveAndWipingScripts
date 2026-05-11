# NAS Setup

`archive_media.sh` writes recovered files (and reports) to a NAS. There are four supported transports, set via `NAS_TRANSPORT` in `config/archive.conf`:

| Transport | When to use |
|-----------|-------------|
| `mounted` | NAS is already mounted via `/etc/fstab` or systemd. Script just verifies. **Recommended** for reliability — you control mount options and credentials in one place. |
| `cifs`    | Mount a SMB/CIFS share at runtime. Most consumer NASes (Synology, QNAP, Buffalo) speak this. |
| `nfs`     | Mount an NFS export at runtime. Common on Linux/BSD NASes and self-built ones. |
| `none`    | Use a local path (testing, single-machine setups, or local Samba sharing from this box). |

## No NAS: share this box over SMB/CIFS

If copied media should live on this machine and be reachable from other computers on the LAN, use the local Samba helper:

```bash
sudo apt install -y samba smbclient cifs-utils acl
sudo ./disktools.sh setup-share
```

By default it creates:

- local directory: `/srv/legacy-media`
- Samba share name: `legacy-media`
- access group: `legacymedia`
- authenticated access for the invoking user

Then configure `config/archive.conf`:

```bash
NAS_TRANSPORT="none"
NAS_DEST="/srv/legacy-media"
```

Or let the helper write those two settings:

```bash
./disktools.sh dest local /srv/legacy-media
```

Connect from another machine with either:

```text
smb://hostname/legacy-media
\\hostname\legacy-media
```

The helper backs up `/etc/samba/smb.conf`, writes a marked share block, validates it with `testparm`, starts `smbd`, and optionally opens the Samba profile in `ufw` if the firewall is active.

## `mounted` — already-mounted (recommended)

Add an entry to `/etc/fstab`. CIFS example:

```fstab
//nas.lan/archive  /mnt/nas  cifs  credentials=/root/.smbcredentials-nas,vers=3.1.1,uid=1000,gid=1000,iocharset=utf8,nofail,_netdev  0  0
```

Replace `uid=1000,gid=1000` with the Linux uid/gid that should own files from the mount (`id -u` and `id -g` show yours).

Credentials file `/root/.smbcredentials-nas` (chmod 600):

```
username=archive
password=...
domain=WORKGROUP
```

Then in `archive.conf`:

```bash
NAS_TRANSPORT="mounted"
NAS_DEST="/mnt/nas/legacy-media"
```

Or:

```bash
./disktools.sh dest mounted /mnt/nas/legacy-media
```

## `cifs` — mount on demand

```bash
NAS_TRANSPORT="cifs"
NAS_CIFS_SHARE="//nas.lan/archive"
NAS_CIFS_MOUNTPOINT="/mnt/nas"
NAS_CIFS_CREDENTIALS="/root/.smbcredentials-nas"
NAS_CIFS_OPTS="vers=3.1.1,uid=$(id -u),gid=$(id -g),iocharset=utf8,nofail,_netdev"
NAS_DEST="/mnt/nas/legacy-media"
```

Required package: `cifs-utils`.

Helper form:

```bash
./disktools.sh dest cifs //nas.lan/archive /mnt/nas /mnt/nas/legacy-media /root/.smbcredentials-nas
```

## `nfs` — mount on demand

```bash
NAS_TRANSPORT="nfs"
NAS_NFS_EXPORT="nas.lan:/volume1/archive"
NAS_NFS_MOUNTPOINT="/mnt/nas"
NAS_NFS_OPTS="vers=4,nofail"
NAS_DEST="/mnt/nas/legacy-media"
```

Required package: `nfs-common`.

Helper form:

```bash
./disktools.sh dest nfs nas.lan:/volume1/archive /mnt/nas /mnt/nas/legacy-media
```

## `none` — local path

Useful for testing or when there's literally nowhere remote to push:

```bash
NAS_TRANSPORT="none"
NAS_DEST="/srv/legacy-media"
```

## Reachability check

After mounting, `archive_media.sh` writes a small probe file to `NAS_DEST` and removes it. If that fails, the script aborts before touching the source media — better to fail fast than to image a flaky disc and discover the destination is read-only at copy time.

## Permissions and ownership

The script runs as root (it has to, for `ddrescue` and `mount`). At every checkpoint that writes to the NAS or to `~/drive_reports/`, ownership is fixed to `${SUDO_USER}` so you can read the results without `sudo` afterwards.

If your CIFS mount is forced to a single uid (via `uid=` mount option), the chown is a no-op — that's expected.

## Network considerations

- ddrescue does its work locally (`SCRATCH_DIR`); only the rsync step crosses the network. Keep `SCRATCH_DIR` on a fast local disk.
- If the NAS link drops mid-rsync, rerun the same case directory — `rsync -a` will resume.
- For very large dumps (DVD images, multi-GB hard drives), consider switching to `rsync --partial --append-verify` by editing `copy_to_nas` in `archive_media.sh`.
