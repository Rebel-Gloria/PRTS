#!/usr/bin/env python3
"""Offline identity check for the bundled Apple model; does not download or upload anything."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def verify():
    provenance = json.loads((ROOT / 'App/Models/provenance.json').read_text())
    assert provenance['repository'] == 'apple/coreml-depth-anything-v2-small'
    assert provenance['revision'] == 'cfef6f6f2a70783dedc0bfae40cecbc2052285d3'
    for item in provenance['files']:
        relative = item['path']
        assert relative == 'README.md' or relative.startswith('DepthAnythingV2SmallF16.mlpackage/')
        assert '..' not in Path(relative).parts
        path = ROOT / 'App/Models' / ('AppleModelCard.txt' if relative == 'README.md' else relative)
        data = path.read_bytes()
        assert len(data) == item['bytes'], f'{path}: size mismatch'
        assert hashlib.sha256(data).hexdigest() == item['sha256'], f'{path}: SHA256 mismatch'
    print(json.dumps({'repository': provenance['repository'], 'revision': provenance['revision'], 'verifiedFiles':len(provenance['files'])}))
if __name__ == '__main__':
    verify()
