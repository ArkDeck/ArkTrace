#!/usr/bin/env python3
"""Pin inherited real counter DTOs/canonical facts and embed them for stock Cargo runner."""
import hashlib,json,shutil
from pathlib import Path
OWN=Path(__file__).resolve().parent;ROOT=OWN.parents[1]
THIRD=ROOT.parent/'parallel-repository-inspector-parity-20261004'
SOURCE=THIRD/'tools/parallel-repository-inspector-parity-20261004'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def main():
 names=['minimal-valid-rust-output.json','minimal-valid-swift-output.json','bounded-sealed-rust-output.json','bounded-swift-output.json']
 pins=[]
 for name in names:
  p=SOURCE/'fixtures'/name;target=OWN/'fixtures'/name;shutil.copyfile(p,target)
  pins.append(dict(path=p.relative_to(THIRD).as_posix(),byteCount=p.stat().st_size,sha256=digest(p)))
 for name in ['observe-minimal-valid','swift-minimal-valid','observe-bounded-sealed','swift-bounded']:
  receipt=SOURCE/'verification'/(name+'.receipt.json');r=read(receipt);log=THIRD/r['log']
  assert r['exitCode']==0 and digest(log)==r['sha256'] and log.stat().st_size==r['byteCount']
  shutil.copyfile(receipt,OWN/'receipts'/('inherited-'+receipt.name));shutil.copyfile(log,OWN/'receipts'/('inherited-'+log.name))
  pins.extend([dict(path=p.relative_to(THIRD).as_posix(),byteCount=p.stat().st_size,sha256=digest(p))for p in [receipt,log]])
 for name in ['swift-source-identities.json','rust-source-identities.json']:
  p=SOURCE/'verification'/name;shutil.copyfile(p,OWN/'receipts'/('inherited-'+name));pins.append(dict(path=p.relative_to(THIRD).as_posix(),byteCount=p.stat().st_size,sha256=digest(p)))
 cases=[]
 for rn,sn in [('minimal-valid-rust-output.json','minimal-valid-swift-output.json'),('bounded-sealed-rust-output.json','bounded-swift-output.json')]:
  rust=read(OWN/'fixtures'/rn);swift={x['id']:x for x in read(OWN/'fixtures'/sn)}
  for r in rust:
   rows=r['repositoryPage']['items']
   if not rows or not all('samples'in row for row in rows):continue
   s=swift[r['id']];assert r['repositoryPage']==s['repositoryPage']
   cases.append(dict(id=r['id'],queryRange=r['actualQuery']['range'],series=rows,swiftFacts=s['facts'],
     producerInput=rn,canonicalInput=sn))
 assert len(cases)==6 and sum(len(c['swiftFacts'])for c in cases)==11
 data=json.dumps(cases,ensure_ascii=False,separators=(',',':'))+'\n';(OWN/'fixtures/canonical-counters.json').write_text(data,encoding='utf-8')
 (OWN/'receipts/inherited-pins.json').write_text(json.dumps(dict(sourceSnapshot=str(THIRD),pins=pins,cases=6,facts=11,fieldsPerFact=19,
  scope='Existing real SQLite/typed repositories and actual Swift loader results inherited; no new producer run or invented Swift output.'),ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 template=(OWN/'test-template.rs.txt').read_text(encoding='utf-8');code=template.replace('EMBEDDED_CANONICAL_JSON',data)
 (ROOT/'rust/crates/arktrace-viewer/tests/inspector_counter_compat_regressions.rs').write_text(code,encoding='utf-8')
 print('inherited six real counter cases / eleven canonical 19-field facts; generated 18 guard/canonical combinations')
if __name__=='__main__':main()
