# Maintenance scripts

- `validate_spatial.sh` — package tests, contract tests, Python tests and unsigned app builds.
- `pull_diag.py` — copies the selected app's local Diagnostics directory from a connected device.
- `read_diag.py` / `summarize_session.py` — inspect DIAG exports without uploading data.
- `test_*.py` — reader, summary and source-structure regression tests.

Scripts are intentionally offline except for the device copy operation requested by the caller. They must not infer sensor truth from missing records.
