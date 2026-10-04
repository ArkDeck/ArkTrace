#!/usr/bin/env python3
"""Encode actual nullable model fields for handoff, without SQL/count/reduction."""
import copy,hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];OWN=Path(__file__).resolve().parent
load=lambda p:json.loads(p.read_text(encoding='utf-8'))
def pin(p):return dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),byteCount=p.stat().st_size)
def save(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def issues(v):
    for i in v:
        for key in ('scope','count','message'):i.setdefault(key,None)
    return v
canon=load(OWN/'fixtures/canonical-15.json');requests={r['id']:r for r in load(OWN/'fixtures/requests.json')}
gold=[]
for record in canon['records']:
    r=dict(id=record['id'],request=requests[record['id']],status=record['status'],canonicalOrigin='original Swift invocation, not generated expected count algorithm')
    if 'facts' in record:r['facts']=copy.deepcopy(record['facts'])
    if 'summaryOriginalEncoder' in record:
        r['summary']=copy.deepcopy(record['summaryOriginalEncoder']);issues(r['summary']['dataQuality']['issues'])
    if 'error' in record:r['error']=copy.deepcopy(record['error'])
    gold.append(r)
zero=load(OWN/'fixtures/controlled-construction-provenance.json')['zeroDurationRejected']
gold.append(dict(id='zero-duration-schema-validation',status='error',kind='controlledSchemaValidation',input='trace_range(1000,1000)',
    observed=zero,summaryFactsInvoked=False,canonicalOrigin='original TraceDatabaseStagingPreparer/TraceSchemaAdapter validation; top-level fatal error retained, no guessed query response'))
metadata=copy.deepcopy(canon['fixtures'])
for f in metadata:
    issues(f['metadata']['dataQuality']['issues']);f.pop('openStatements')
save(OWN/'fixtures/handoff-golden.json',dict(schemaVersion=1,status='actualSwiftCanonicalOnly',records=gold,metadata=metadata,
    originalCanonical=pin(OWN/'fixtures/canonical-15.json'),encodingNote='Only explicit null insertion for known optional fields; original model encoders retained alongside. All counts, flags, quality values and array order untouched.',
    totalNewControls=16,successfulStoreCalls=9,successfulOriginalAnalysisConsumerCalls=1,expectedSwiftErrorRequests=5,schemaValidationErrorControls=1))
proposal=dict(status='proposalOnlyNotSharedImplementation',operation='summaryFacts',wireSchemaVersion=1,
    request=dict(range='optional trace-relative signed Int64 ns; nil is inclusive entire trace, supplied range is strictly half-open 0<=start<end<=duration',
        maximumRowsPerSection=dict(type='integer',minimum=1,maximum=1000000,observedTarget='process/thread source prefix'),
        maximumEventsPerSection=dict(type='integer',minimum=1,maximum=1000000,default='maximumRowsPerSection at original query constructor'),
        timeout='bounded duration converted to local monotonic deadline; do not serialize Swift ContinuousClock.Instant; Analysis original timeout is (0,300] s'),
    response=dict(required=['processCount','threadCount','warnings','qualityIssues'],nullable=['cpuCount','cpuSliceCount','threadStateCount','namedSliceCount','counterSeriesCount','eventCountBySource'],
        boundedCount=dict(value='nonnegative Int64',truncated='Boolean; true includes incomplete budget or excluded invalid directory lifecycle, not just output length'),
        eventCountBySource=dict(value='{items:[{source:UTF-8 String,count:nonnegative Int64}],truncated:Bool} or explicit null',
            availability='Only nil range plus compatible stat table; explicit even whole-duration range must be null',ordering='original UTF-8 byte ordering, preserve actual items'),
        qualityIssue=dict(category='original typed category vocabulary',scope='optional original scope',count='optional Int64, unknown probe tail is null',message='optional safe original message'),
        warnings='actual original strings/order; query facts are separate from metadata quality; original Analysis merges/deduplicates/sorts'),
    errors=dict(observedInvalid='INVALID_ARGUMENT/request/retryable=false; empty, out-of-duration, row budget 0 before SQL',
        observedSwiftDeadline='QUERY_TIMEOUT/querying/retryable=true; expired at entry before VM execution',
        observedSwiftCancellation='Raw CancellationError from original Store for pre-cancelled Task; no normalized CANCELLED observed here',
        recommendedNativeCancellation='Native typed cancellation must retain its own actual bounded admission/interrupt/cleanup evidence; map only at authorized public contract boundary, never convert arbitrary failure into cancellation'),
    budgetSemantics=dict(directory='rowid source prefix (budget+1 probe), then lifecycle inclusion/filter; unknown NULL start retained with unavailableValue; invalid end<=start excluded with lower-bound flag',
        stat='source prefix then received/count/label validation and reduction; dropped non-received rows alone do not imply truncation, invalid/unchecked rows can',
        events='temporal WHERE first, LIMIT budget+1 matching rows, then COUNT/min; not uniform raw-source-row bound',
        cpu='whole-trace topology DISTINCT CPU after valid event predicate, LIMIT distinct CPUs; independent requested range',
        counter='time-qualified DISTINCT(sample-table,filter-id), ordered LIMIT then map against separate prefix-limited filter tables; sample-table/scope identity retained',
        unresolvedRequirement='If native product requires all sections source-row bounded before filtering/reduction, that is not fixed 817 Swift compatibility for events/CPU/counter. Resolve/version explicitly and measure actual native work; this task does not silently relax that requirement.'),
    semanticFindings=['Zero-duration SQLite trace is rejected by original validation despite summaryFacts nil-range comment allowing degenerate Core range.',
        'Final zero-duration sched/thread-state/callstack events admitted for nil range, excluded for explicit [0,duration). Process/thread end==start remains invalid lifecycle.',
        'Unknown start_ts is counted with unavailableValue; it is not dropped or zeroed. Uninspected lifecycle tail gets probeTruncated with count null.',
        'Original synthesized TraceSummaryFacts encoder omits absent optionals; golden wire explicitly inserts null. Original TraceSummary count encoder already emits null, quality issue optionals are synthesized/omitted.'],
    nativeEvidence=dict(executed=False,frozenNativeInterfaceSupplied=False,fixed817InterfaceMissing=True,artifact='none selected; no unstable working-tree source used',
        notProven=['native Store summary parity','native deadline during VM','native cancellation admission/interrupt','SDK/FFI summary owner budgets','App/CLI integration','production publisher runtime','CI lanes']))
save(OWN/'fixtures/interface-proposal.json',proposal)
checks=[]
for label,cmd in [('fixed-history-gap-search',['rg','-n','summaryFacts|summary_facts|TraceSummaryFacts','docs/migration-runs','rust','Sources/ArkTraceRustRuntime','--glob','*.md','--glob','*.rs','--glob','*.swift','--glob','*.py','--max-count','2']),
    ('fixed-interface-gap-search',['rg','-n','summaryFacts|summary_facts|SummaryFacts|pub.*summary','rust/crates/arktrace-store/src','Sources/ArkTraceRustRuntime','bindings/c','contracts'])]:
    result=subprocess.run(cmd,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8')
    assert result.returncode in (0,1);p=OWN/'verification'/(label+'.log');p.write_text(result.stdout,encoding='utf-8')
    checks.append(dict(command=cmd,cwd=str(ROOT),exitCode=result.returncode,log=pin(p)))
save(OWN/'fixtures/history-and-native-gap-assessment.json',dict(checks=checks,
    conclusion='Within fixed snapshot reports and native/SDK source, no exact existing actual Store-summary canonical; only deferred gaps, forwarding or cancellation stubs and inventory declarations. This is a targeted gap claim, not a full historical audit.',
    nativeInterface='No implemented fixed817 Store/SDK/FFI summaryFacts entry identified, no separately delivered frozen native summary artifact used.',
    repeatedHistoricalMatrices=[],sourceSnapshot=pin(ROOT/'parallel-snapshot.json')))
print(json.dumps(dict(records=len(gold),nativeParityExecuted=False,golden=pin(OWN/'fixtures/handoff-golden.json'))))
