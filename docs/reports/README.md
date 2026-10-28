# Build reports

Dated, point-in-time records: what changed in a build, how it was tested and what was installed.
They are history, not the current design. For the current structure see
[architecture](../architecture/README.md).

- `*_YYYY-MM-DD.md` — build reports and code audits, newest date wins when they disagree.
- `evidence/` — the JSON evidence lists (log hashes, test counts) referenced by those reports.
