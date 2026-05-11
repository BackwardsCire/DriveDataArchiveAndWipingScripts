---
description: Summarize recent archive/rescue/wipe sessions in ~/drive_reports/.
---

Inspect `~/drive_reports/` and report on the most recent sessions:

1. List the newest 10 entries (sessions, case directories, FAILED/SUCCESS subfolders) with their UTC timestamps.
2. For each archive case, parse the `report.txt` if present and pull: media type, bytes recovered, bad sectors remaining, recovery passes used, NAS destination path.
3. Flag anything that looks unfinished — a `.img` with no companion `report.txt`, a ddrescue mapfile with non-zero bad-sector count, or a rsync transcript with errors.
4. End with a short recommendation: which case (if any) might be worth a deeper recovery pass, and which look ready to be marked done.

Do not delete or move anything; this command is read-only.
