# Security Policy

These scripts touch raw block devices and (for the wipe tool) cause irreversible data loss. Treat security reports against them as high priority.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository, or email the maintainer at the address listed in `git log` for the most recent commit. Please **do not** open a public issue for vulnerabilities.

Useful information to include:
- Which script and version (`git rev-parse HEAD`).
- Ubuntu version and kernel (`uname -a`).
- The exact command line, including any environment variables (`DRY_RUN`, `ALLOW_NONUSB`, etc.).
- Source media type (USB Zip, USB CD/DVD, USB-HDD, NVMe).
- A minimal reproducer or trace from `~/drive_reports/session_*.log`.

## What we consider a vulnerability

- Anything that lets the wipe script target the system disk despite the USB-only / mount-point guards.
- Code execution from a crafted source medium (e.g. via filename handling in the rsync / mount steps).
- Credential leakage from `archive.conf` or NAS credential files into logs / reports.
- Privilege escalation past the explicit `sudo` step.

## What we don't consider a vulnerability

- The wipe script wiping the disk you told it to wipe.
- ddrescue producing an empty or partial image when the source medium is failing.
- A misconfigured NAS mount returning errors.

## Defensive defaults you should keep

- USB-only on the wipe tool unless you have a specific reason to flip `ALLOW_NONUSB=1`.
- Source-device read-only until the image is captured (the orchestrator never opens the source `rw`).
- `DRY_RUN=1` for any new test scenario before running for real.
- Run interactively under `tmux` — never background a wipe or a long ddrescue pass without one.
