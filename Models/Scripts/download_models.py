#!/usr/bin/env python3
"""Download source checkpoints used by the local PRTS model pipeline."""
from pathlib import Path
from urllib.request import urlretrieve
import hashlib

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "Source" / "yolo11n-seg.pt"
URL = "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n-seg.pt"
EXPECTED = "55ed65c56c91713d23e8402371c6c49a6fd84f257f7dce452e8d70e41dcbe152"

if not TARGET.exists():
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    urlretrieve(URL, TARGET)
actual = hashlib.sha256(TARGET.read_bytes()).hexdigest()
if actual != EXPECTED:
    raise SystemExit(f"SHA-256 mismatch: {actual}")
print(f"verified {TARGET} ({actual})")
