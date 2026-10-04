#!/usr/bin/env python3
"""Exclusive pinned runner, exact commands/logs, and no production dependency edits."""
from pathlib import Path
import hashlib, json, os, subprocess, sys
ROOT=Path(__file__).resolve().parents[4]
CRATE=ROOT/'rust/crates/arktrace-viewer'
cache=Path(os.environ['ARKTRACE_CARGO_CACHE_ROOT']).resolve()
assert not cache.is_relative_to(ROOT)
env=os.environ.copy();env.update(GIT_DIR=str(cache/'source-index.git'),GIT_WORK_TREE=str(ROOT),CARGO_NET_OFFLINE='true')
subprocess.run(['git','add','.'],cwd=ROOT,env=env,check=True)
commands=[('format',['python3','scripts/run-cargo.py','fmt','--all']),('fmt-check',['python3','scripts/run-cargo.py','fmt','--all','--check']),('clippy',['python3','scripts/run-cargo.py','clippy','--workspace','--all-targets','--','-D','warnings']),('viewer-tests',['python3','scripts/run-cargo.py','test','-p','arktrace-viewer','--','--nocapture']),('workspace',['python3','scripts/verify_rust_workspace.py']),('licenses',['sh','scripts/verify_licenses.sh'])]
folder=CRATE/'tests/fixtures/snapshot-event-index-verification';folder.mkdir(exist_ok=True)
receipts=[]
for label,cmd in commands:
 log=folder/f'{label}.log'
 with log.open('w',encoding='utf-8') as out: run=subprocess.run(cmd,cwd=ROOT,env=env,stdout=out,stderr=subprocess.STDOUT)
 data=log.read_bytes();receipt=dict(command=cmd,cwd=str(ROOT),exitCode=run.returncode,log=str(log.relative_to(ROOT)),sha256=hashlib.sha256(data).hexdigest(),byteCount=len(data),environment={'ARKTRACE_CARGO_CACHE_ROOT':str(cache),'GIT_DIR':env['GIT_DIR'],'GIT_WORK_TREE':env['GIT_WORK_TREE'],'CARGO_NET_OFFLINE':'true'})
 receipts.append(receipt)
 (folder/'receipt.json').write_text(json.dumps(receipts,indent=2)+'\n',encoding='utf-8')
 print(json.dumps({'check':label,'exitCode':run.returncode}),flush=True)
 if run.returncode:
  print(log.read_text(encoding='utf-8')[-8000:]);sys.exit(run.returncode)
