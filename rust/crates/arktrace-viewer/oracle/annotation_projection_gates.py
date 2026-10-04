#!/usr/bin/env python3
"""Freeze exact correction gate commands and UTF-8 logs in its own cache."""
import datetime, hashlib, json, os, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[4]
CACHE = ROOT.parent / 'caches/parallel-annotations-review-fix-cargo'
EVIDENCE = CACHE / 'frozen-evidence'
def main():
 EVIDENCE.mkdir(parents=True, exist_ok=True)
 runner = 'rust/crates/arktrace-viewer/oracle/annotation_projection_validate.py'
 gates = [('format', ['fmt','--all']), ('fmt', ['fmt','--all','--','--check']), ('test', ['test','-p','arktrace-viewer','--offline']), ('clippy', ['clippy','-p','arktrace-viewer','--all-targets','--offline','--','-D','warnings']), ('verify', ['verify'])]
 records = []
 for name, args in gates:
  log = EVIDENCE / f'annotation-projection-{name}.log'
  command = [sys.executable, runner, *args]
  started = datetime.datetime.now(datetime.timezone.utc).isoformat()
  with log.open('w', encoding='utf-8') as output:
   code = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT).returncode
  data = log.read_bytes()
  records.append(dict(name=name,command=command,workingDirectory=str(ROOT),startedAtUtc=started,finishedAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(),exitCode=code,log=dict(path=str(log),byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())))
  (EVIDENCE/'command-results.json').write_text(json.dumps(records,indent=2)+'\n',encoding='utf-8')
  print(name, code, flush=True)
  if code: print(log.read_text(encoding='utf-8')[-6000:]); return code
 return 0
if __name__ == '__main__': sys.exit(main())
