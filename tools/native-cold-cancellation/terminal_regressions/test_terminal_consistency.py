# N49 exact six cases / thirty pre-registered checks; full protocol stays inert.
import copy,hashlib,json,time
from pure_loader import T,R,load_terminal

def compact(x):return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()

def run_group(group_start,group_deadline,task_clock):
    oracle=json.loads((R/'registration/oracle.json').read_bytes())
    fixture_body=(T/'fixtures.json').read_bytes();assert hashlib.sha256(fixture_body).hexdigest()==oracle['fixturesSHA256']
    fixtures=json.loads(fixture_body);schema=json.loads((R/'registration/schema-premises.json').read_bytes())
    terminal=load_terminal();cancel_cell={'cancelled':False};trusted_cancel=lambda:cancel_cell['cancelled']
    synthetic_bytes=20907;checkpoint_calls=0
    def require(ok,key):
        if not ok:raise AssertionError(key)
    def checkpoint():
        nonlocal checkpoint_calls
        checkpoint_calls+=1
        require(type(trusted_cancel()) is bool and not trusted_cancel(),'trusted_fixture_cancel_checkpoint')
        require(time.monotonic_ns()<group_deadline,'original_group_deadline_checkpoint')
    def uint(v):return type(v) is int and 0<=v<=2**64-1
    def failure_shape(f):
        require(type(f) is dict and set(f)=={'type','code','stage','isCancellation'},'failure_exact_keys')
        require(type(f['type']) is str and 0<len(f['type'])<=512 and type(f['isCancellation']) is bool,'failure_exact_types')
        for k in ('code','stage'):require(f[k] is None or type(f[k]) is str and 0<len(f[k])<=512,'failure_nullable_string')
    def payload_shape(m):
        for r in (m['returned'],m['joined']):
            require(type(r['success']) is bool,'success_exact_bool');failure_shape(r['failure'])
        for r in (m['joined'],m['result']):
            require(type(r['cancelMeasured']) is bool and uint(r['cancelCalls']),'metrics_exact_types')
            for k in ('cancelToJoinedNs','joinWaitNs'):require(r[k] is None or uint(r[k]),'metric_nullable_uint')
            require(r['joinWaitScope'] is None or type(r['joinWaitScope']) is str,'scope_nullable_string')
            require(r['withinCancelSLO'] is None or type(r['withinCancelSLO']) is bool,'slo_nullable_bool')
        require(type(m['result']['passed']) is bool and type(m['result']['normalShutdownJoined']) is bool,'result_exact_bool')
        for k in ('cancel_before','cancel_after'):
            if m[k] is not None:require(uint(m[k]['callMonotonicNs']) and uint(m[k]['cancelCalls']),'cancel_exact_uint')
    def canonical_wire_shape(mode):
        records=fixtures['canonicalSchemaWire'][mode]
        require(len(records)<=256,'bounded_synthetic_records');total=0;last_clock=0
        for i,r in enumerate(records):
            event=r['event'];required=set(schema['envelope'])|set(schema['fields'][event]);allowed=required|set(schema['optional'].get(event,[]))
            require(required<=set(r)<=allowed,'canonical_schema_exact_fields')
            require(type(r['schemaVersion']) is int and r['schemaVersion']==3 and uint(r['sequence']) and r['sequence']==i+1,'canonical_schema_sequence')
            require(r['clockID']==schema['clockID'] and uint(r['monotonicNs']) and r['monotonicNs']>=last_clock,'canonical_synthetic_clock_shape');last_clock=r['monotonicNs']
            require(type(r['controlNonce']) is str and r['controlNonce']=='00000000-0000-4000-8000-000000000049','canonical_fixture_nonce')
            for k in ('success','unexpectedSuccess','normalPublicSDK','measuredGate','passed','normalShutdownJoined','completeProcessForestProven','postShutdownHandleQueryExecuted'):
                if k in r:require(type(r[k]) is bool,'canonical_wire_bool')
            for k in ('pid','parentPID','timeoutMilliseconds','openTasks','callMonotonicNs','cancelCalls','joinedMonotonicNs','cancelSLOMilliseconds'):
                if k in r:require(uint(r[k]),'canonical_wire_uint')
            if 'failure' in r and r['failure'] is not None:failure_shape(r['failure'])
            for k in ('privateColdCounts','privateRequestCounts','descendantActualExitCodes','descendantWaitReaped'):
                if k in r:require(r[k] is None,'canonical_private_proof_null')
            if 'completeProcessForestProven' in r:require(r['completeProcessForestProven'] is False,'canonical_no_forest_authority')
            # Compact serialization used only for bounded schema checking; count it.
            body=compact(r);nonlocal_bytes[0]+=len(body);total+=len(body)
            require(len(body)<=65536 and total<=131072,'canonical_wire_byte_bounds')
        m=fixtures['models'][mode];payload_shape(m)
        j=m['joined']
        if j['cancelMeasured']:
            require(j['joinWaitNs'] is None and j['joinWaitScope'] is None and type(j['withinCancelSLO']) is bool and uint(j['cancelToJoinedNs']),'canonical_measured_metric_shape')
        else:require(j['cancelToJoinedNs'] is None and j['withinCancelSLO'] is None and uint(j['joinWaitNs']) and j['joinWaitScope']=='ordinaryJoinOrUnmeasuredCleanup','canonical_unmeasured_metric_shape')
    def joined(m):return terminal.validate_join(m['returned'],m['joined'],m['cancel_before'],m['cancel_after'])
    def result_check(m):
        events=m['events'];shutdown='engine.shutdown.joined' in events and 'engine.shutdown.failure' not in events;cleanup='cleanup.flush.joined' in events;failed='consumer.failure' in events
        return terminal.validate_result(m['returned'],m['joined'],m['result'],m['cancel_before'],m['cancel_after'],shutdown,cleanup,failed)
    nonlocal_bytes=[0];rows=[]
    for case in oracle['cases']:
        row=dict(name=case['name'],plannedChecks=case['checkCount'],executed=False,**{'pass':False},fail=False,unstarted=True,checks=[]);rows.append(row)
        if time.monotonic_ns()>=group_deadline:continue
        row.update(executed=True,unstarted=False,startMonotonicNS=time.monotonic_ns())
        for name in case['checks']:
            check=dict(name=name,executed=False,**{'pass':False},fail=False,unstarted=True)
            row['checks'].append(check)
            if time.monotonic_ns()>=group_deadline:continue
            check.update(executed=True,unstarted=False);expected=oracle['expected'][case['name']][name]
            try:
                checkpoint();m=copy.deepcopy(fixtures['models']['measured']);category=case['name'];action='result'
                if category==oracle['cases'][0]['name']:action=name
                elif category==oracle['cases'][1]['name']:m=copy.deepcopy(fixtures['models']['unmeasured' if name=='unmeasured-false' else 'noncancel']);action='false-result'
                elif category==oracle['cases'][2]['name']:m['joined']['failure']=dict(type='Swift.CancellationError',code=None,stage=None,isCancellation=True)
                elif category==oracle['cases'][3]['name']:
                    changes=dict(cancelMeasured=False,cancelCalls=2,cancelToJoinedNs=250000001,joinWaitNs=0,joinWaitScope='ordinaryJoinOrUnmeasuredCleanup',withinCancelSLO=False);m['result'][name]=changes[name]
                elif category==oracle['cases'][4]['name']:
                    if name=='missing-shutdown':m['events']=['cleanup.flush.joined']
                    elif name=='failed-shutdown':m['events']=['engine.shutdown.before','engine.shutdown.failure','cleanup.flush.joined']
                    elif name=='missing-cleanup':m['events']=['engine.shutdown.before','engine.shutdown.joined']
                    elif name=='cleanup-failure-consumer-event':m['events']=['engine.shutdown.before','engine.shutdown.joined','consumer.failure']
                    elif name=='consumer-failure':m['events'].append('consumer.failure')
                    else:m['result']['normalShutdownJoined']=False
                else:
                    f=m['returned']['failure']
                    if name=='wrong-type':f['type']='Fixture.OtherError'
                    elif name=='ark-code':f['code']='OTHER_SYNTHETIC_CODE'
                    elif name=='ark-stage':f['stage']='ready'
                    elif name in ('rust-code','rust-stage'):f.update(type='ArkTraceRustRuntime.RustAdmission',code='8' if name=='rust-code' else '9',stage=None if name=='rust-code' else 'parsing')
                    elif name in ('swift-code','swift-stage'):f.update(type='Swift.CancellationError',code='CANCELLED' if name=='swift-code' else None,stage=None if name=='swift-code' else 'request')
                    elif name=='cancellation-flag-false':f['isCancellation']=False
                    elif name=='over-SLO':m['joined'].update(joinedMonotonicNs=1100000001,cancelToJoinedNs=1000000001,withinCancelSLO=False);m['result'].update({k:m['joined'][k] for k in terminal.METRIC_KEYS})
                    elif name=='SLO-claim-mismatch':m['joined']['withinCancelSLO']=False;m['result']['withinCancelSLO']=False
                    else:m=copy.deepcopy(fixtures['models']['unmeasured']);m['result']['passed']=True
                    if name not in ('over-SLO','SLO-claim-mismatch','unmeasured-claims-passed'):m['joined']['failure']=copy.deepcopy(f)
                payload_shape(m);trial_body=compact(m);synthetic_bytes+=len(trial_body)
                require(synthetic_bytes+nonlocal_bytes[0]<=65536,'cumulative_synthetic_byte_cap')
                caught=None;returned=None
                try:
                    if action=='schema-and-join':canonical_wire_shape('measured');returned=joined(m)
                    elif action=='typed-cancellation':returned=terminal.cancellation(m['returned']['failure']);require(returned is True,'canonical_typed_cancel')
                    elif action=='duration-and-SLO':require(m['joined']['cancelToJoinedNs']==250000000 and m['joined']['joinedMonotonicNs']-m['cancel_before']['callMonotonicNs']==250000000 and m['joined']['withinCancelSLO'] is True and m['joined']['cancelCalls']==1,'canonical_duration_slo');returned=joined(m)
                    elif action=='false-result':canonical_wire_shape('unmeasured' if name=='unmeasured-false' else 'noncancel');returned=result_check(m);require(returned is True and m['result']['passed'] is False,'false_preserved_no_product_pass')
                    else:returned=result_check(m)
                except terminal.TerminalProofError as error:caught=error
                error_text=None if caught is None else str(caught)
                check.update(actualOriginalExceptionType=None if caught is None else type(caught).__module__+'.'+type(caught).__name__,actualOriginalErrorText=error_text,originalFiniteCodeAvailable=False,helperReturn=returned,resultPassed=m['result']['passed'],syntheticTrialBytes=len(trial_body))
                if expected['outcome']=='REJECT':require(type(caught) is terminal.TerminalProofError and error_text==expected['errorText'],'expected_original_rejection')
                else:
                    require(caught is None,'expected_acceptance')
                    if action in ('result-with-shutdown-cleanup-metrics','false-result'):require(returned is True,'consistent_result_return')
                checkpoint();require(synthetic_bytes+nonlocal_bytes[0]<=65536,'cumulative_synthetic_byte_cap');check['pass']=True
            except Exception as error:check.update(fail=True,finiteFailureType=type(error).__name__,finiteAssertion=str(error) if type(error) is AssertionError else 'unexpected_fixture_error')
        row['endMonotonicNS']=time.monotonic_ns();row['pass']=len(row['checks'])==case['checkCount'] and all(c['executed'] and c['pass'] and not c['fail'] and not c['unstarted'] for c in row['checks']);row['fail']=not row['pass']
    end=time.monotonic_ns();total_synthetic=synthetic_bytes+nonlocal_bytes[0]
    status='PASS' if len(rows)==6 and all(r['pass'] for r in rows) and end<=group_deadline and total_synthetic<=65536 else 'HOLD'
    return dict(schemaVersion=1,task='N49',status=status,plannedCases=6,plannedChecks=30,groupRuns=1,groupStartMonotonicNS=group_start,groupOriginalDeadlineMonotonicNS=group_deadline,groupEndMonotonicNS=end,groupElapsedNS=end-group_start,taskOriginalClock=task_clock,cases=rows,syntheticPreparedBytes=20907,syntheticTrialBytes=synthetic_bytes-20907,syntheticCanonicalSchemaSerializationBytes=nonlocal_bytes[0],totalSyntheticBytes=total_synthetic,trustedFixtureCheckpointCalls=checkpoint_calls,trustedFixtureCancelState=cancel_cell['cancelled'],terminalHelperHasBudgetCancellationInterface=False,fullProtocolDecoderExecuted=False,SwiftCompileCount=0,SwiftRuntimeCount=0,actualProductCancellation=False,sourceUnmodified=True)
