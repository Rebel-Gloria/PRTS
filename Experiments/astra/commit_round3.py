#!/usr/bin/env python3
"""After .git write access is restored: commit separate changes and replay after each commit.
Never changes a remote, pushes, or rewrites the working-tree product files.
"""
import hashlib,json,os,pathlib,subprocess,sys
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[1]
series=json.loads((HERE/'round3-patches/series.json').read_text())
def run(args,**kw):return subprocess.run(args,cwd=ROOT,check=True,**kw)
def read(args):return subprocess.check_output(args,cwd=ROOT,text=True).strip()
assert read(['git','branch','--show-current'])=='main','requires main'
assert read(['git','rev-parse','HEAD'])==series['baseline'],'HEAD changed; review instead of restaging automatically'
run(['git','diff','--cached','--quiet'])
source=pathlib.Path(read([sys.executable,str(HERE/'round3_sources.py')]))
for change in series['changes']:
 for name in change['files']:
  assert (ROOT/name).read_bytes()==(source/'step5'/name).read_bytes(),f'working file changed: {name}'
co='Co-Authored-By: GPT-6 Astra <noreply@openai.com>'
tools=['.gitignore','README.md','run.sh','run_round2.sh','ReplayProduct.swift','metrics_product.py','prepare_product.py','seal_product.py','report_product.py','round3_sources.py','run_round3.sh','run_product.sh','commit_round3.py','round3-patches']
run(['git','add','--',*[str((HERE/n).relative_to(ROOT)) for n in tools]])
run(['git','commit','-m','增加产品源码重放和第三轮指标','-m',co])
def replay(label):
 env=dict(os.environ,ASTRA_SOURCE_ROOT=str(source/label))
 run(['zsh',str(HERE/'run_product.sh'),label,*sys.argv[1:]],env=env)
replay('baseline')
for change in series['changes']:
 patch=HERE/'round3-patches'/change['patch']
 # Stage only this patch against the previous commit; the working tree already holds all five.
 run(['git','apply','--cached','--check',str(patch)])
 run(['git','apply','--cached',str(patch)])
 run(['git','commit','-m',change['subject'],'-m',co])
 replay('step'+str(change['number']))
for label in ['only1','only2','only3']:replay(label)
run([sys.executable,str(HERE/'report_product.py')])
run(['git','add','--','ASTRA_ROUND3.md'])
run(['git','commit','-m','记录第三轮完整重放结果','-m',co])
