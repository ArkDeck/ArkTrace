#!/usr/bin/env python3
"""Freeze the task's actual commands and independent-cache logs."""
import datetime,hashlib,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
EVIDENCE=ROOT.parent/'caches/parallel-inspector-projection-cargo/frozen-evidence'
def main():
 EVIDENCE.mkdir(parents=True,exist_ok=True);record=EVIDENCE/'command-results.json';records=json.loads(record.read_text(encoding='utf-8'))if record.exists()else[]
 rust='rust/crates/arktrace-viewer/oracle/inspector_projection_validate.py';swift='rust/crates/arktrace-viewer/oracle/inspector_projection_swift.py'
 gates=[('swiftOracle',[swift]),('swiftRegressions',[swift,'--regressions']),('fmt',[rust,'fmt','--all','--','--check']),('test',[rust,'test','-p','arktrace-viewer','--offline']),('clippy',[rust,'clippy','-p','arktrace-viewer','--all-targets','--offline','--','-D','warnings']),('verify',[rust,'verify'])]
 for name,args in gates:
  number=len(records)+1;log=EVIDENCE/f'inspector-projection-{number:02}-{name}.log';command=[sys.executable,*args];started=datetime.datetime.now(datetime.timezone.utc).isoformat()
  with log.open('w',encoding='utf-8')as output:code=subprocess.run(command,cwd=ROOT,stdout=output,stderr=subprocess.STDOUT).returncode
  data=log.read_bytes();records.append(dict(name=name,command=command,workingDirectory=str(ROOT),startedAtUtc=started,finishedAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(),exitCode=code,log=dict(path=str(log),byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())))
  if name.startswith('swift'):
   actual=ROOT.parent/'caches/parallel-inspector-projection-swiftpm'/('inspector-projection-swift-oracle.log'if name=='swiftOracle'else'inspector-projection-swift-regressions.log');copy=EVIDENCE/f'inspector-projection-{number:02}-{name}-actual.log';copy.write_bytes(actual.read_bytes());data=copy.read_bytes();records[-1]['actualLog']=dict(path=str(copy),byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())
  record.write_text(json.dumps(records,indent=2)+'\n',encoding='utf-8');print(name,code,flush=True)
  if code:print(log.read_text(encoding='utf-8')[-6000:]);return code
 return 0
if __name__=='__main__':sys.exit(main())
