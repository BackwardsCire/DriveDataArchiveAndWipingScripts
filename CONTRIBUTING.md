# Contributing

Thanks for helping improve Disk Tools! To keep changes safe and reviewable:

1. **Discuss first** - Open an issue for new features or behavior changes.
2. **Keep safety in mind** - Avoid reducing safeguards (USB-only defaults, confirmations) without clear justification.
3. **Coding style** - Bash with `set -euo pipefail`; prefer POSIX utilities; keep logs and prompts concise.
4. **Testing** - Use `DRY_RUN=1` for wipe flows when possible; capture relevant excerpts of `session_*.log` for bug reports.
5. **Pull requests** - Describe the scenario, Ubuntu version, hardware/enclosure type, and include any failure logs.

Security reports should follow `SECURITY.md`.

