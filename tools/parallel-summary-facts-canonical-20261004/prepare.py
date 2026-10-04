#!/usr/bin/env python3
"""Fixed 817b33d canonical source mirror; data construction only, no count oracle."""
import hashlib, json, os, re, shutil, sqlite3, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]; OWN=Path(__file__).resolve().parent
SWIFT=ROOT.parent/'caches/parallel-summary-facts-canonical-swiftpm'
NATIVE=ROOT.parent/'caches/parallel-summary-facts-canonical-native'
OLD=ROOT.parent/'parallel-sdk-directory-swift-parity-20261004'
def pin(p):
    d=p.read_bytes();return dict(path=str(p),byteCount=len(d),sha256=hashlib.sha256(d).hexdigest())
def save(p,v):
    p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def dbpin(p):
    s=p.stat(); con=sqlite3.connect('file:'+str(p)+'?mode=ro',uri=True)
    schema=con.execute("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name,tbl_name").fetchall();con.close()
    return dict(**pin(p),device=s.st_dev,inode=s.st_ino,mode=oct(s.st_mode&0o777),mtimeNs=s.st_mtime_ns,ctimeNs=s.st_ctime_ns,
        schemaSHA256=hashlib.sha256(json.dumps(schema,ensure_ascii=False,separators=(',',':')).encode('utf-8')).hexdigest(),schema=[list(r) for r in schema])
manifest=json.loads((ROOT/'parallel-snapshot.json').read_text(encoding='utf-8'))
assert manifest['fixedCommit']=='817b33d39a9b7211039472ee80f076edd2dadc18'
for r in manifest['files']:assert pin(ROOT/r['path'])['sha256']==r['sha256'],r['path']
assert not SWIFT.exists() and not NATIVE.exists()
SWIFT.mkdir(parents=True); NATIVE.mkdir(parents=True)
source=SWIFT/'oracle-source'; source.mkdir()
sources=[]
for module in ('ArkTraceCore','ArkTraceStore','ArkTraceAnalysis'):
    shutil.copytree(ROOT/'Sources'/module,source/'Sources'/module)
    for p in sorted((ROOT/'Sources'/module).rglob('*.swift')):
        row=next(r for r in manifest['files'] if r['path']==p.relative_to(ROOT).as_posix())
        sources.append(dict(original=pin(p),gitBlob=row['gitBlob'],gitBlobSHA256=row['gitBlobSHA256'],copy=pin(source/p.relative_to(ROOT))))
shutil.copytree(ROOT/'scripts',source/'scripts')
aug=source/'Sources/ArkTraceStore/SQLiteTraceRepository.swift'
original=aug.read_bytes(); aug.write_bytes(original+b'\n'+(OWN/'swift/RepositoryAccess.swift').read_bytes())
assert aug.read_bytes().startswith(original)
target=source/'Sources/SummaryOracle';target.mkdir();shutil.copyfile(OWN/'swift/SummaryOracle.swift',target/'SummaryOracle.swift')
(source/'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package=Package(name:"ArkTraceSummaryCanonical",platforms:[.macOS(.v26)],targets:[
 .target(name:"ArkTraceCore",swiftSettings:[.strictMemorySafety()]),
 .target(name:"ArkTraceStore",dependencies:["ArkTraceCore"],swiftSettings:[.strictMemorySafety()]),
 .target(name:"ArkTraceAnalysis",dependencies:["ArkTraceCore"],swiftSettings:[.strictMemorySafety()]),
 .executableTarget(name:"SummaryOracle",dependencies:["ArkTraceCore","ArkTraceStore","ArkTraceAnalysis"],swiftSettings:[.strictMemorySafety(),.unsafeFlags(["-parse-as-library"])])
],swiftLanguageModes:[.v6])
''',encoding='utf-8')
subprocess.run(['git','init','--quiet'],cwd=source,check=True)
save(OWN/'fixtures/oracle-source-identities.json',dict(sources=sources,augmentedRepository=pin(aug),seam=pin(OWN/'swift/RepositoryAccess.swift'),
    originalPrefixByteCount=len(original),harness=pin(target/'SummaryOracle.swift'),package=pin(source/'Package.swift'),rootPackageReadOnly=pin(ROOT/'Package.swift')))
fixtures=[]; evidence=[]
for name,sha,size in [('zlib','004cca580c192cb04d940d1e275dfffc9ff667c0b851e91dfaa2710242299a4a',2351104),
    ('hiprofiler_data_ability','b9c19f1a3ccf53e75864a4d465d087fe61be46bc32fe11c1f5f4c413c5b7732a',2072576)]:
    delivered=ROOT.parent/'delivery-evidence/sdk-directory-swift-parity-20261004'/(name+'.db')
    assert not delivered.is_symlink() and pin(delivered)['sha256']==sha and delivered.stat().st_size==size
    inp=OLD/'tools/parallel-sdk-directory-swift-parity-20261004/fixtures'/('private-runtime-'+name+'-oracle-input.json')
    opening=inp.with_name('private-runtime-'+name+'-opening.json');v=json.loads(inp.read_text(encoding='utf-8'));op=json.loads(opening.read_text(encoding='utf-8'))
    assert v['preparation']==op['opening']['metadata']['databasePreparation'] and v['parserIdentity']==op['opening']['metadata']['parser']
    assert v['source']['sha256']==op['opening']['metadata']['sourceSHA256'] and v['source']['byteCount']==op['opening']['metadata']['sourceByteCount']
    target=NATIVE/(name+'.db');shutil.copyfile(delivered,target);target.chmod(0o400)
    raw=ROOT/'Fixtures/traces'/(name+'.htrace');assert pin(raw)['sha256']==v['source']['sha256'] and raw.stat().st_size==v['source']['byteCount']
    fixtures.append(dict(id=name,database=str(target),parserIdentity=v['parserIdentity'],source=v['source'],preparation=v['preparation'],constructionSQL=None))
    shutil.copyfile(inp,OWN/'fixtures'/inp.name);shutil.copyfile(opening,OWN/'fixtures'/opening.name)
    evidence.append(dict(id=name,deliveredDB=dbpin(delivered),currentCapture=dbpin(target),historicalInput=pin(inp),historicalOpening=pin(opening),rawTrace=pin(raw),
        identityRelationship='same recorded SHA256/size and preparation/parser/source metadata; fresh capture inode, not historical live SDK connection'))
repo=(ROOT/'Tests/ArkTraceStoreTests/RepositoryTests.swift').read_text(encoding='utf-8')
block=repo[repo.index('    private func makeSummaryRepository('):repo.index('    private func makeTemporaryDatabase(')]
sql=block.split('"""',2)[1]; idx=repo.split('private static let requiredDensityIndexesSQL = """',1)[1].split('"""',1)[0]
sql=sql.replace('\\(Self.requiredDensityIndexesSQL)',idx).replace('\\(extraSQL)','')
assert '\\(' not in sql
endpoint='''
INSERT INTO process VALUES (6, 106, 'final-instant', 2000, 2000);
INSERT INTO thread VALUES (6, 106, 'final-instant', 2000, 2000, 6);
INSERT INTO sched_slice VALUES (5, 2000, 0, 4, 6, 6);
INSERT INTO thread_state VALUES (4, 2000, 0, 4, 6, 'R');
INSERT INTO callstack VALUES (4, 2000, 0, 6, 'final-instant');
INSERT INTO measure VALUES (2000, 2, 1);
'''
controlledSQL=sql+endpoint
zeroSQL='''CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
INSERT INTO trace_range VALUES (1000,1001);
CREATE TABLE process (ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);
CREATE TABLE thread (itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);
'''+repo.split('private static let requiredEventTablesSQL = """',1)[1].split('"""',1)[0]
parser=dict(name='trace_streamer',reportedVersion='4.3.7',binarySHA256='0'*64,upstreamRepository='https://example.invalid/trace_streamer.git',upstreamRevision='1'*40,
    architecture='arm64',adapterVersion='1',buildRecipeVersion='1')
for name,sql in [('temporal',controlledSQL),('empty-absent',zeroSQL)]:
    sqlfile=OWN/'fixtures'/(name+'-construction.sql');sqlfile.write_text(sql,encoding='utf-8')
    fixtures.append(dict(id=name,database=str(NATIVE/(name+'.db')),parserIdentity=parser,source=dict(sha256=pin(sqlfile)['sha256'],byteCount=sqlfile.stat().st_size),preparation=None,constructionSQL=sql))
save(OWN/'fixtures/controlled-construction-provenance.json',dict(originalTestSource=pin(ROOT/'Tests/ArkTraceStoreTests/RepositoryTests.swift'),
    originalFunctionSHA256=hashlib.sha256(block.encode('utf-8')).hexdigest(),baseSQLSHA256=hashlib.sha256(controlledSQL.removesuffix(endpoint).encode('utf-8')).hexdigest(),endpointAdditions=endpoint,
    note='Temporal base SQL extracted literally from original test fixture; only owned final-instant rows added. Empty fixture uses original required event-table DDL and a zero-duration trace; no expected count algorithm. Real original preparer and validated repository open.'))
requests=[]
def case(id,fixture,range=None,rows=100000,events=100000,consumer='store',deadline=30000,cancel=False):
    requests.append(dict(id=id,fixture=fixture,consumer=consumer,range=None if range is None else dict(startNs=range[0],endNs=range[1]),
        maximumRowsPerSection=rows,maximumEventsPerSection=events,deadlineMilliseconds=deadline,preCancelled=cancel))
case('zlib-full','zlib');case('zlib-explicit-full','zlib',(0,32210627000))
case('ability-full','hiprofiler_data_ability')
case('ability-event-budget-1','hiprofiler_data_ability',events=1)
case('temporal-full','temporal');case('temporal-explicit-full','temporal',(0,1000));case('temporal-half-open','temporal',(200,400))
case('temporal-source-budget-before-filter','temporal',(200,400),rows=1,events=1)
case('analysis-source-budget-consumer','temporal',(200,400),rows=1,events=1,consumer='analysis')
case('empty-full-unsupported-null','empty-absent');case('invalid-empty-query','empty-absent',(0,0))
case('invalid-range-past-duration','temporal',(0,1001));case('invalid-row-budget-zero','temporal',rows=0)
case('expired-swift-deadline','temporal',deadline=-1);case('pre-cancelled-swift-task','temporal',cancel=True)
assert len(requests)==15
save(OWN/'fixtures/input-construction.json',dict(fixtures=fixtures,requests=requests));save(OWN/'fixtures/requests.json',requests)
save(OWN/'fixtures/real-capture-provenance.json',evidence)
print(json.dumps(dict(baselineFiles=len(manifest['files']),originalSwiftSources=len(sources),requests=len(requests),realDBs=2,controlledDBs=2)))
