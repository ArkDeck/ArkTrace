#!/usr/bin/env python3
"""Read-only receipt verification; no new Store requests or surrogate oracle."""
import hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];OWN=Path(__file__).resolve().parent
SWIFT=ROOT.parent/'caches/parallel-summary-facts-canonical-swiftpm';NATIVE=ROOT.parent/'caches/parallel-summary-facts-canonical-native'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text(encoding='utf-8'))
def pin(p):return dict(path=str(p),byteCount=p.stat().st_size,sha256=sha(p))
def save(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
manifest=load(ROOT/'parallel-snapshot.json');assert len(manifest['files'])==1311
for r in manifest['files']:
    p=ROOT/r['path'];assert p.is_file() and not p.is_symlink() and sha(p)==r['sha256'],r['path']
ident=load(OWN/'fixtures/oracle-source-identities.json');compiled=load(OWN/'fixtures/compiled-identities.json')
assert len(ident['sources'])==28
for r in compiled['sources']:assert sha(Path(r['path']))==r['sha256']
for r in ident['sources']:
    original=Path(r['original']['path']);assert sha(original)==r['gitBlobSHA256']
    current=SWIFT/'runner/workspace'/original.relative_to(ROOT)
    if original.name=='SQLiteTraceRepository.swift':
        assert current.read_bytes()==original.read_bytes()+b'\n'+(OWN/'swift/RepositoryAccess.swift').read_bytes()
    else:assert current.read_bytes()==original.read_bytes()
assert sha(SWIFT/'runner/workspace/Sources/SummaryOracle/SummaryOracle.swift')==sha(OWN/'swift/SummaryOracle.swift')
assert sha(Path(compiled['executable']['path']))==compiled['executable']['sha256']
sourceRecord=load(OWN/'fixtures/input-observation.json');canonical=load(OWN/'fixtures/canonical-15.json')
requests=sourceRecord['requests'];records=canonical['records'];byid={r['id']:r for r in records}
assert len(requests)==len(records)==len(byid)==15 and len(requests)+1==16
assert {r['id'] for r in requests}==set(byid)
assert canonical['outsideMainThread'] and all(r['outsideMainThread'] for r in records+canonical['fixtures'])
assert sum(r['status']=='success' for r in records)==10 and sum(r['status']=='error' for r in records)==5
countKeys=['cpuCount','processCount','threadCount','cpuSliceCount','threadStateCount','namedSliceCount','counterSeriesCount']
optional=['cpuCount','cpuSliceCount','threadStateCount','namedSliceCount','counterSeriesCount','eventCountBySource']
wireKeys=set(countKeys+['eventCountBySource','warnings','qualityIssues'])
for r in records:
    if 'facts' not in r:continue
    f=r['facts'];assert set(f)==wireKeys
    original=r['factsOriginalEncoder']
    for k in countKeys:
        if f[k] is not None:assert set(f[k])=={'value','truncated'} and f[k]['value']>=0 and isinstance(f[k]['truncated'],bool)
    for k in optional:assert f[k]==original.get(k)
    for issue in f['qualityIssues']:assert set(issue)=={'category','scope','count','message'}
    for issue,o in zip(f['qualityIssues'],original['qualityIssues']):assert all(issue[k]==o.get(k) for k in issue)
    assert f['warnings']==original['warnings']
empty=byid['empty-full-unsupported-null']['facts']
assert all(empty[k] is None for k in optional)
assert empty['processCount']==empty['threadCount']==dict(value=0,truncated=False)
full=byid['temporal-full']['facts'];explicit=byid['temporal-explicit-full']['facts']
assert (full['cpuSliceCount']['value'],explicit['cpuSliceCount']['value'])==(5,4)
assert (full['threadStateCount']['value'],explicit['threadStateCount']['value'])==(4,3)
assert (full['namedSliceCount']['value'],explicit['namedSliceCount']['value'])==(4,3)
assert full['cpuCount']==explicit['cpuCount']==dict(value=5,truncated=False)
assert explicit['eventCountBySource'] is None and full['eventCountBySource']==dict(items=[dict(source='ftrace',count=4),dict(source='trace',count=5)],truncated=True)
half=byid['temporal-half-open']['facts'];low=byid['temporal-source-budget-before-filter']['facts']
assert half['processCount']==dict(value=2,truncated=True)
assert low['processCount']==low['threadCount']==dict(value=0,truncated=True)
assert all(i['category']=='probeTruncated' and i['count'] is None for i in low['qualityIssues'])
assert low['namedSliceCount']==dict(value=1,truncated=False) and low['counterSeriesCount']==dict(value=1,truncated=False)
assert any('SELECT DISTINCT cpu' in s['sql'] and 'WHERE' in s['sql'] for s in byid['temporal-half-open']['observedStatements'])
assert any('FROM process' in s['sql'] and 'ORDER BY rowid ASC LIMIT ?' in s['sql'] and 'WHERE' not in s['sql'] for s in byid['temporal-source-budget-before-filter']['observedStatements'])
summary=byid['analysis-source-budget-consumer']['summaryOriginalEncoder']
for k in countKeys:assert summary[k]==(None if low[k] is None else low[k]['value'])
assert summary['eventCountBySource'] is None and summary['range']==dict(startNs=200,endNs=400)
assert summary['truncatedSections']==['cpuCount','processCount','threadCount','cpuSliceCount','threadStateCount']
assert summary['dataQuality']['status']=='warnings' and len(summary['dataQuality']['issues'])==4
for id in ('invalid-empty-query','invalid-range-past-duration','invalid-row-budget-zero'):
    r=byid[id];assert r['error']['code']=='INVALID_ARGUMENT' and r['error']['stage']=='request' and not r['error']['retryable'] and r['error']['publicContractViolation'] is None
    assert r['observedStatements']==[]
e=byid['expired-swift-deadline']['error'];assert e['code']=='QUERY_TIMEOUT' and e['stage']=='querying' and e['retryable'] and e['publicContractViolation'] is None
assert byid['pre-cancelled-swift-task']['error']==dict(kind='CancellationError',typedPublicError=None)
assert load(OWN/'fixtures/database-before.json')==load(OWN/'fixtures/database-after.json')
assert load(OWN/'fixtures/directory-members-before.json')==load(OWN/'fixtures/directory-members-after.json')
for old,cur in zip(load(OWN/'fixtures/database-after.json'),canonical['fixtures']):
    assert old['id']==cur['id'] and old['facts']['device']==cur['databaseDevice'] and old['facts']['inode']==cur['databaseInode']
for r in load(OWN/'fixtures/real-capture-provenance.json'):
    for key in ('deliveredDB','currentCapture','historicalInput','historicalOpening','rawTrace'):
        assert sha(Path(r[key]['path']))==r[key]['sha256']
    f=next(f for f in canonical['fixtures'] if f['id']==r['id']);opening=load(Path(r['historicalOpening']['path']))['opening']
    assert f['metadata']['parser']==opening['metadata']['parser'] and f['metadata']['schemaFingerprint']==opening['metadata']['schemaFingerprint']
    assert f['metadata']['traceSHA256']==opening['metadata']['traceSHA256'] and f['metadata']['durationNs']==opening['inspection']['durationNs']
for label in ('valid-empty-fixture-oracle-build','valid-range-construction','once-canonical-15'):
    rec=load(OWN/'verification'/(label+'.receipt.json'));assert rec['exitCode']==0 and rec['warnings']==[] and sha(Path(rec['log']['path']))==rec['log']['sha256']
failed=load(OWN/'verification/first-construction.receipt.json');assert failed['exitCode']==-5 and 'end_ts > start_ts' in (OWN/'verification/first-construction.log').read_text(encoding='utf-8')
report=dict(status='pass',baselineFiles=1311,originalSwiftSources=28,successfulRequests=10,expectedErrorRequests=5,actualSummaryRequests=15,actualSchemaRejectionControls=1,
    boundedTotal=16,controlledDBs=2,realCapturedDBs=2,unchangedDBs=4,allOffMainThread=True,
    nativeParityExecuted=False,nativeDeadlineOrCancellationProven=False,cancellationObserved='original Swift CancellationError at already-cancelled Task entry, no public typed translation',
    budgetSemantics='directory/stat/filter-table prefixes before filtering; events limit matching rows; CPU/counter queries DISTINCT before LIMIT; no uniform source-row bound claim',
    canonical=pin(OWN/'fixtures/canonical-15.json'),compiledExecutable=compiled['executable'])
save(OWN/'verification/canonical-verification.json',report);print(json.dumps(report))
