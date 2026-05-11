# Install Guide

## Prerequisites
- Ubuntu 25.04 or newer
- sudo access for installing packages and accessing block devices
- `tmux` for long-running sessions (Zip imaging can run for hours)

## Install packages

### Archive workflow (Zip / CD / DVD / legacy HDD → NAS)

Required:
```bash
sudo apt update
sudo apt install -y \
  gddrescue parted rsync file util-linux coreutils \
  hfsprogs hfsutils ntfs-3g exfatprogs \
  genisoimage tmux
```

NAS transport (pick what your NAS speaks):
```bash
sudo apt install -y cifs-utils      # for SMB/CIFS NASes
sudo apt install -y nfs-common      # for NFS exports
```

No NAS? Share this box over SMB/CIFS after archive runs:
```bash
sudo apt install -y samba smbclient cifs-utils acl
sudo ./disktools.sh setup-share
```

That creates a local Samba share for `/srv/legacy-media`. Then set:
```bash
./disktools.sh dest local /srv/legacy-media
```

Optional fallback tools (recommended — they kick in only if ddrescue leaves bad sectors):
```bash
sudo apt install -y dvdisaster cdparanoia safecopy
```

### Wipe workflow

```bash
sudo apt install -y \
  smartmontools e2fsprogs nwipe enscript ghostscript nvme-cli \
  util-linux usbutils tmux gdisk parted gawk sed grep
```

## Get the scripts
```bash
git clone https://github.com/your-org/disk-tools.git disk-tools
cd disk-tools
chmod +x scripts/*.sh
```

## Configure the archive workflow

```bash
cp config/archive.conf.example config/archive.conf
# Edit NAS_DEST, NAS_TRANSPORT, and (for cifs/nfs) the mount-specific keys.
# See docs/nas_setup.md for the supported transports.
```

## Verify tools are reachable
```bash
# Archive workflow
command -v ddrescue ddrescuelog parted rsync file mount tmux blkid isoinfo

# Optional fallbacks (missing ones are just skipped at runtime)
command -v dvdisaster cdparanoia safecopy

# Local SMB/CIFS share server (only if using setup-share)
command -v testparm smbpasswd smbclient
systemctl status smbd --no-pager

# Wipe workflow
command -v smartctl badblocks nwipe enscript ps2pdf
```

If any **required** command is missing, rerun `apt install` for that package.
