#!/usr/bin/env python3
"""Verify copied compilation inputs and seal the binary/tool fingerprint after execution."""
import hashlib,json,pathlib,subprocess
from prepare import HERE
manifest=HERE/'results/product_manifest.json';m=json.loads(manifest.read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for name,entry in m['sources'].items():
 copy=HERE/'generated/ProductCore'/pathlib.Path(name).relative_to('Vendor/SpatialCore')
 assert sha(copy)==entry['source']==entry['copy'],name
m['binarySHA256']=sha(HERE/'bin/replay-product')
m['swiftVersion']=subprocess.check_output(['swift','--version'],text=True).strip()
m['tools']={name:sha(HERE/name) for name in ['ReplayProduct.swift','prepare_product.py','metrics_product.py','metrics.py','run_product.sh','seal_product.py']}
manifest.write_text(json.dumps(m,indent=2))
