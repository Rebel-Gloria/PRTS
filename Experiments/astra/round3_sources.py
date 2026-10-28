#!/usr/bin/env python3
"""Reconstruct cumulative and single-change PRODUCT sources without touching the checkout."""
import argparse,hashlib,json,pathlib,shutil,subprocess,tempfile
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[1]
series=json.loads((HERE/'round3-patches/series.json').read_text())
ap=argparse.ArgumentParser();ap.add_argument('--out',type=pathlib.Path);args=ap.parse_args()
out=args.out or pathlib.Path(tempfile.mkdtemp(prefix='astra-round3-'))
out.mkdir(parents=True,exist_ok=True)
base=out/'baseline';base.mkdir(exist_ok=True)
archive=subprocess.Popen(['git','archive',series['baseline'],'Vendor/SpatialCore','PRTS/Feedback','PRTS/Spatial/Runtime','PRTS/Spatial/Rendering','PRTS/UI','PRTS/Localizable.xcstrings','docs/architecture','Experiments/SpatialProbe/Core/Sources/SpatialCore'],cwd=ROOT,stdout=subprocess.PIPE)
subprocess.run(['tar','-x','-C',str(base)],stdin=archive.stdout,check=True);archive.stdout.close();assert archive.wait()==0
patches=[]
for change in series['changes']:
 p=HERE/'round3-patches'/change['patch'];assert hashlib.sha256(p.read_bytes()).hexdigest()==change['sha256'];patches.append(p)
for i in range(1,6):
 dest=out/f'step{i}'
 if dest.exists():raise SystemExit(f'refusing to overwrite {dest}')
 shutil.copytree(out/('baseline' if i==1 else f'step{i-1}'),dest)
 subprocess.run(['patch','--batch','--forward','-p1','-i',str(patches[i-1])],cwd=dest,stdout=subprocess.DEVNULL,check=True)
for i in [1,2,3]:
 dest=out/f'only{i}';shutil.copytree(base,dest)
 subprocess.run(['patch','--batch','--forward','-p1','-i',str(patches[i-1])],cwd=dest,check=True,stdout=subprocess.DEVNULL)
print(out)
