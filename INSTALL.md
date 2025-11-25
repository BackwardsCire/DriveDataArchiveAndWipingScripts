# Install Guide

## Prerequisites
- Ubuntu 25.04 or newer
- sudo access for installing packages and accessing disks
- `tmux` for long-running sessions

## Install packages
```bash
sudo apt update
sudo apt install -y smartmontools e2fsprogs nwipe enscript ghostscript nvme-cli \
  util-linux usbutils coreutils tmux gdisk parted gawk sed grep
sudo apt install -y gddrescue pv ntfs-3g exfatprogs hfsprogs hfsutils zip unzip
```

## Get the scripts
```bash
git clone https://github.com/your-org/disk-tools.git disk-tools
cd disk-tools
chmod +x scripts/*.sh
```

## Verify tools are reachable
```bash
command -v smartctl badblocks nwipe enscript ps2pdf ddrescue tmux
```

If any command is missing, rerun the install step or install the specific package noted in the README.
