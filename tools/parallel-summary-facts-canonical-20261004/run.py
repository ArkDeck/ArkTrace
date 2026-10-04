#!/usr/bin/env python3
"""Bounded actual Swift build/construct/observe, using exclusive runner/cache."""
import hashlib,json,os,re,shutil,sqlite3,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];OWN=Path(__file__).resolve().parent
SWIFT=ROOT.parent/'caches/parallel-summary-facts-canonical-swiftpm';NATIVE=ROOT.parent/'caches/parallel-summary-facts-canonical-native'
def pin(p):
    d=p.read_bytes();return dict(path=str(p),byteCount=len(d),sha256=hashlib.sha256(d).hexdigest())
def save(p,v):
    p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def dbpin(p):
    s=p.stat();c=sqlite3.connect('file:'+str(p)+'?mode=ro',uri=True)
    schema=c.execute("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name,tbl_name").fetchall();c.close()
    return dict(**pin(p),device=s.st_dev,inode=s.st_ino,mode=oct(s.st_mode&0o777),mtimeNs=s.st_mtime_ns,ctimeNs=s.st_ctime_ns,
        schemaSHA256=hashlib.sha256(json.dumps(schema,ensure_ascii=False,separators=(',',':')).encode('utf-8')).hexdigest(),schema=[list(r) for r in schema])
env=os.environ.copy();env.update(PYTHONDONTWRITEBYTECODE='1',MACOSX_DEPLOYMENT_TARGET='26.0',ARKTRACE_SWIFTPM_CACHE_ROOT=str(SWIFT/'runner'))
for key in ('GIT_DIR','GIT_WORK_TREE','ARKTRACE_RUST_XCFRAMEWORK','ARKTRACE_RUST_SDK_FIXTURES'):env.pop(key,None)
def execute(label,cmd,cwd):
    log=OWN/'verification'/(label+'.log');assert not log.exists(),label;start=time.monotonic()
    with log.open('w',encoding='utf-8') as f:r=subprocess.run(cmd,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
    receipt=dict(command=cmd,cwd=str(cwd),exitCode=r.returncode,elapsedSeconds=time.monotonic()-start,log=pin(log),
        warnings=re.findall(r'^.*warning:.*$',log.read_text(encoding='utf-8'),flags=re.MULTILINE),
        environment={k:env[k] for k in ('MACOSX_DEPLOYMENT_TARGET','ARKTRACE_SWIFTPM_CACHE_ROOT')})
    save(log.with_suffix('.receipt.json'),receipt);print(json.dumps(receipt),flush=True)
    if r.returncode: print(log.read_text(encoding='utf-8')[-12000:]);raise SystemExit(r.returncode)
    assert not receipt['warnings'];return receipt
action=sys.argv[1];attempt=sys.argv[2] if len(sys.argv)>2 else 'first'
source=SWIFT/'oracle-source';binary=SWIFT/'runner/build/out/Products/Debug/SummaryOracle'
if action=='build':
    shutil.copyfile(OWN/'swift/SummaryOracle.swift',source/'Sources/SummaryOracle/SummaryOracle.swift')
    execute(attempt+'-oracle-build',['sh','scripts/run-swiftpm.sh','build','--disable-sandbox','--config-path',str(SWIFT/'runner/configuration'),
        '--security-path',str(SWIFT/'runner/security'),'--product','SummaryOracle','-Xswiftc','-warnings-as-errors'],source)
    save(OWN/'fixtures/compiled-identities.json',dict(executable=pin(binary),sources=[pin(p) for p in sorted((SWIFT/'runner/workspace/Sources').rglob('*.swift'))],
        package=pin(SWIFT/'runner/workspace/Package.swift')))
    tc={}
    for name,cmd in [('swift',['swift','--version']),('xcode',['xcodebuild','-version']),('sdk',['xcrun','--show-sdk-path']),('os',['sw_vers']),('machO',['vtool','-show-build',str(binary)])]:
        rr=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8');tc[name]=dict(command=cmd,exitCode=rr.returncode,output=rr.stdout);assert rr.returncode==0
    save(OWN/'verification/toolchain.json',tc)
elif action in ('construct','repair-construction'):
    inp=OWN/'fixtures/input-construction.json';rec=execute(attempt+'-construction',[str(binary),action,str(inp)],NATIVE)
    result=json.loads((OWN/'verification'/(attempt+'-construction.log')).read_text(encoding='utf-8'))
    assert len(result['created'])==2
    v=json.loads(inp.read_text(encoding='utf-8'));byid={r['id']:r for r in result['created']}
    for f in v['fixtures']:
        if f['id'] in byid:
            assert byid[f['id']]['outsideMainThread'];f['preparation']=byid[f['id']]['preparation'];Path(f['database']).chmod(0o400)
    save(OWN/'fixtures/input-observation.json',v)
    save(OWN/'fixtures/database-before.json',[dict(id=f['id'],facts=dbpin(Path(f['database']))) for f in v['fixtures']])
elif action=='observe':
    inp=OWN/'fixtures/input-observation.json';v=json.loads(inp.read_text(encoding='utf-8'));assert len(v['requests'])==15
    before=json.loads((OWN/'fixtures/database-before.json').read_text(encoding='utf-8'))
    actual=[dict(id=f['id'],facts=dbpin(Path(f['database']))) for f in v['fixtures']];assert actual==before
    save(OWN/'fixtures/directory-members-before.json',sorted(p.name for p in NATIVE.iterdir()))
    execute(attempt+'-canonical-15',[str(binary),'observe',str(inp)],NATIVE)
    result=json.loads((OWN/'verification'/(attempt+'-canonical-15.log')).read_text(encoding='utf-8'))
    save(OWN/'fixtures/canonical-15.json',result)
    after=[dict(id=f['id'],facts=dbpin(Path(f['database']))) for f in v['fixtures']];save(OWN/'fixtures/database-after.json',after);assert before==after
    assert sorted(p.name for p in NATIVE.iterdir())==json.loads((OWN/'fixtures/directory-members-before.json').read_text(encoding='utf-8'))
    save(OWN/'fixtures/directory-members-after.json',sorted(p.name for p in NATIVE.iterdir()))
    print(json.dumps(dict(requests=len(result['records']),statuses={key:sum(r['status']==key for r in result['records']) for key in ('success','error')},databasesUnchanged=True)))
else:raise SystemExit('unknown action')
