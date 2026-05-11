---
description: List candidate source media (Zip, optical, HDD) currently visible to the kernel.
---

Run `scripts/detect_media.sh` and present the results in a compact table the user can act on.

Steps:
1. Execute `bash scripts/detect_media.sh` (no sudo needed for the read-only enumeration).
2. Summarize the output: device path, kind (zip/optical/hdd/usb-other), size, model, current mount state, and whether any filesystem signature was detected.
3. Highlight anything unusual: devices with no readable signature, devices reporting kernel I/O errors, optical drives reporting `no medium`.
4. If the user has not yet picked a device, ask which one they want to archive next. Do not start `archive_media.sh` automatically — that's destructive of time, not data, but still a deliberate step.
