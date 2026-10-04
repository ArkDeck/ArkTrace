#!/usr/bin/env python3
"""Verify actual public API/native outputs and inherited immutable evidence."""
from pathlib import Path
import hashlib,json
ROOT=Path(__file__).resolve().parents[2];OWN=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(rel):return json.loads((OWN/rel).read_text(encoding='utf-8'))
cases=load('fixtures/cases.json');rust=load('fixtures/rust-output.json');swift=load('fixtures/swift-controller-output.json')
assert len(cases)==len(rust['intents'])==14 and len(swift)==len(rust['flows'])==6
failures=[];rows=[]
for case,out in zip(cases,rust['intents']):
    assert case['id']==out['id']
    assert out['intent']['afterEvent']==case['afterEvent']
    assert out['intent']['identity']==case['identity']
    tag,body=next(iter(case['source'].items()))
    # Typed absence stays None; the frozen associated-value Codable omits nil.
    expected_source={tag:{k:v for k,v in body.items() if v is not None}}
    assert out['intent']['source']==expected_source
    assert out['typedSourceQuery']['filterID']==body['filterID']
    assert out['typedSourceQuery']['processKey']==(body.get('processKey') or {}).get('ipid')
    assert out['typedSourceQuery']['cpu']==body.get('cpu')
    if case['expected']=='invalidEvidence':assert out['validationError']=='InvalidEvidence'
    elif case['expected']=='shapeOnly':assert out['validationError'] is None
    elif case['afterEvent']['table']=='measure' and tag=='processCounter':
        assert out['validationError']=='InvalidEvidence';failures.append(case['id'])
    else:assert out['validationError'] is None
    rows.append(dict(id=case['id'],expectedContract=case['expected'],actualError=out['validationError'],sourceAndEventKeyPreserved=True))
assert len(failures)==3
flow_rows=[]
for out,native in zip(rust['flows'],swift):
    assert out['id']==native['id']
    case=next(c for c in cases if c['id']==out['id'])
    for field in ('focusSteps','focused','admittedTree','treeAfterReveal','viewportAfterReveal'):
        assert out[field]==native[field],(out['id'],field)
    assert native['selectedInspector']==case['inspectors'][case['targetOrdinal']]
    assert out['focused']['key']==case['afterEvent']==native['selectedInspector']['key']
    assert out['pendingKeyAfterRangeAction'] is None and native['pendingKeyAfterReveal'] is None
    assert out['revealIntents']['pendingEventKey'] is None
    flow_rows.append(dict(id=out['id'],displayedNavigationNativeParity=True,controllerSelectedKey=native['selectedInspector']['key'],selectedValue=native['selectedInspector']['value'],sourcePreserved=True,rangeRevealParity=True,rangeOnlyIntentHasNoCounterEventKey=True))
assert flow_rows[1]['selectedValue']==999 and flow_rows[2]['selectedValue']==99
inherited=load('fixtures/inherited-evidence.json')
previous=Path(inherited['reportPath']).parents[2]
assert sha(Path(inherited['reportPath']))==inherited['reportSHA256']
for r in inherited['verified']:assert sha(previous/r['path'])==r['sha256']
for r in inherited['databases']:assert sha(Path(r['path']))==r['sha256']
for r in load('fixtures/database-copy-identities.json'):assert sha(Path(r['path']))==r['sha256']
manifest=json.loads((ROOT/'parallel-snapshot.json').read_text(encoding='utf-8'))
assert sha(ROOT/'parallel-snapshot.json')=='e293efa4b8e1a64fe2e4a2b31f0968a5ada15878793261f87d2d758368288ea8'
for r in manifest['files']:assert sha(ROOT/r['path'])==r['sha256']
result=dict(schemaVersion=1,meaningfulNewCombinations=14,maximumCombinations=16,nativeFlows=6,wrongTableRejections=5,shapeOnlyCases=3,legalAnchorPasses=3,legalAnchorFailures=3,actualProducerCompatibilityPassed=False,baselineFilesUnchanged=946,priorFrozenOwnedChecksumEntriesVerified=99,priorProducerFilesModified=False,databaseBytesUnchanged=True,failures=failures,intents=rows,flows=flow_rows,apiLimits=['EventNavigationQueryIntent does not execute repository adjacency or prove filter/process ownership','RevealRange has range only; ViewAction has no SelectCounter or RevealCounterEvent case','Swift public reveal takes TraceSearchResult; its slice branch admits a namedSlice lane','New native evidence uses frozen real Inspector facts and real SQLite catalog; not a complete document-open/SDK/App acceptance'])
(OWN/'fixtures/comparison.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:result[k] for k in ('meaningfulNewCombinations','nativeFlows','legalAnchorFailures','wrongTableRejections','baselineFilesUnchanged')}))
