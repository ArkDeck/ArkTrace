# Exact two new N48 cases, one run, no production constructor or authority.
import hashlib
import json
import time
from pure_loader import load_ingress, load_hash_budget

class SpyDecoder:
    def __init__(self):self.rows=[];self.finish_calls=0;self.terminal=False
    def feed(self,line):
        assert type(line) is bytes and len(line)<=65536 and len(self.rows)<256
        row=dict(fixtureOnly=True,ordinal=len(self.rows)+1,byteCount=len(line),sha256=hashlib.sha256(line).hexdigest(),
                 smallLineASCII=line.decode('ascii') if len(line)<=32 else None)
        self.rows.append(row)
        if line==b'TERMINAL':self.terminal=True
        return row
    def finish(self):
        self.finish_calls+=1
        return dict(complete=self.terminal,spyOnly=True,actualProductAuthority=False)

CASE_NAMES=('first-event-cancel-before-second-frame','first-event-original-deadline-before-second-frame')
INERT_PORT=object()

def run_group(group_start,group_deadline,task_clock):
    oracle=json.loads((__import__('pure_loader').R/'registration/oracle.json').read_bytes())
    Ingress,SupervisorError=load_ingress()
    H=load_hash_budget()
    rows=[]
    for name in CASE_NAMES:
        rows.append(dict(name=name,executed=False,pass_=False,fail=False,unstarted=True))
    def require(condition,key):
        if not condition:raise AssertionError(key)
    for row in rows:
        name=row['name'];case_start=time.monotonic_ns()
        if case_start>=group_deadline:continue
        row.update(executed=True,unstarted=False,caseStartMonotonicNS=case_start)
        deadline=min(group_deadline,case_start+20_000_000) if name==CASE_NAMES[1] else group_deadline
        row['fixtureOriginalDeadlineMonotonicNS']=deadline
        try:
            class Receiver(Ingress):
                def __init__(self):
                    self.cell={'cancelled':False}
                    self.budget=H.HashBudget(H.HashPolicy(1,65536,131072,8192,deadline),lambda:self.cell['cancelled'])
                    self.buffer=bytearray();self.offered_bytes=0;self.record_count=0;self.failure_code=None
                    self.decoder=SpyDecoder();self.events=[];self.check_calls=0;self.wait=None
                def check(self,port):
                    require(port is INERT_PORT,'inert_port_identity');self.check_calls+=1;self.budget.checkpoint()
                def event(self,record,port):
                    require(port is INERT_PORT,'inert_port_identity');self.events.append(record)
                    if len(self.events)==1:
                        if name==CASE_NAMES[0]:self.cell['cancelled']=True
                        else:
                            started=time.monotonic_ns();hard_stop=started+50_000_000;iterations=0
                            while True:
                                now=time.monotonic_ns()
                                if now>=deadline:break
                                require(now<hard_stop,'fixture_wait_bound')
                                time.sleep(min((deadline-now)/1_000_000_000,0.001));iterations+=1
                            ended=time.monotonic_ns()
                            self.wait=dict(startMonotonicNS=started,endMonotonicNS=ended,elapsedNS=ended-started,sleepIterations=iterations,originalDeadlineMonotonicNS=deadline)
                            require(ended-started<=50_000_000,'fixture_wait_elapsed_bound')
            receiver=Receiver();budget=receiver.budget;policy=budget.policy;callback=budget._cancelled
            before=dict(budgetObjectID=id(budget),policyObjectID=id(policy),callbackObjectID=id(callback),policyFields=[policy.schema_version,policy.per_file_max_bytes,policy.total_max_bytes,policy.chunk_bytes,policy.absolute_deadline_ns],hashBytes=budget.bytes_read_total,hashReads=budget.read_calls)
            # One fresh 13-byte synthetic chunk per case; no follow-up feed or finish.
            chunk=b'first\nsecond\n';row['syntheticConstructedBytes']=len(chunk)
            caught=None
            try:receiver.on_stdout_bytes(chunk,INERT_PORT)
            except Exception as error:caught=error
            after=dict(budgetObjectID=id(receiver.budget),policyObjectID=id(receiver.budget.policy),callbackObjectID=id(receiver.budget._cancelled),policyFields=[policy.schema_version,policy.per_file_max_bytes,policy.total_max_bytes,policy.chunk_bytes,policy.absolute_deadline_ns],hashBytes=budget.bytes_read_total,hashReads=budget.read_calls)
            finite_code=caught.code if type(caught) is H.HashBudgetError else None
            row.update(actualExceptionType=None if caught is None else type(caught).__module__+'.'+type(caught).__name__,actualHashBudgetError=type(caught) is H.HashBudgetError,actualCode=finite_code,firstFailureCode=receiver.failure_code,decoderCalls=len(receiver.decoder.rows),eventCalls=len(receiver.events),recordCount=receiver.record_count,checkCalls=receiver.check_calls,offeredBytes=receiver.offered_bytes,bufferBytes=len(receiver.buffer),bufferHex=bytes(receiver.buffer).hex(),bufferSHA256=hashlib.sha256(receiver.buffer).hexdigest(),decodedRows=receiver.decoder.rows,finishCalls=receiver.decoder.finish_calls,cancelCallbackState=receiver.cell['cancelled'],before=before,after=after,fixtureWait=receiver.wait)
            expected=oracle['cases'][name]
            require(type(caught) is H.HashBudgetError,'actual_hash_budget_error_type')
            require(finite_code==expected['errorCode'],'actual_finite_code')
            require(receiver.failure_code==expected['firstFailureCode'],'first_failure_code')
            require(len(receiver.decoder.rows)==len(receiver.events)==receiver.record_count==1,'second_frame_not_decoded_or_dispatched')
            require(receiver.decoder.rows[0]['sha256']==expected['firstLineSHA256'],'first_frame_original')
            require(bytes(receiver.buffer)==bytes.fromhex(expected['remainingBufferHex']),'second_frame_preserved_complete')
            require(receiver.offered_bytes==expected['offeredBytes'],'original_chunk_bookkeeping')
            require(before==after and receiver.budget is budget and receiver.budget.policy is policy and receiver.budget._cancelled is callback,'same_budget_policy_deadline_callback_no_refund')
            require(receiver.decoder.finish_calls==0,'no_finish_execution')
            require(receiver.cell['cancelled']==expected['cancelCallbackAfterEvent'],'original_callback_state')
            if name==CASE_NAMES[1]:
                require(receiver.wait is not None and receiver.wait['endMonotonicNS']>=deadline and receiver.wait['elapsedNS']<=50_000_000,'original_actual_deadline_elapsed')
                require(deadline==min(group_deadline,case_start+20_000_000),'fixture_original_deadline_not_renewed')
            row.update(pass_=True,fail=False)
        except Exception as error:
            row.update(pass_=False,fail=True,failureType=type(error).__name__,finiteAssertion=str(error) if type(error) is AssertionError else 'unexpected_fixture_or_loader_error')
        row['caseEndMonotonicNS']=time.monotonic_ns()
    end=time.monotonic_ns()
    for row in rows:row['pass']=row.pop('pass_')
    status='PASS' if len(rows)==2 and all(r['executed'] and r['pass'] and not r['fail'] and not r['unstarted'] for r in rows) and end<=group_deadline else 'HOLD'
    return dict(schemaVersion=1,task='N48',status=status,plannedCases=2,groupRuns=1,groupStartMonotonicNS=group_start,groupOriginalDeadlineMonotonicNS=group_deadline,groupEndMonotonicNS=end,groupElapsedNS=end-group_start,taskOriginalClock=task_clock,cases=rows,totalSyntheticConstructedBytes=sum(r.get('syntheticConstructedBytes',0) for r in rows),totalOfferedBytes=sum(r.get('offeredBytes',0) for r in rows),actualHashReadBytes=0,actualHashReadCalls=0,scope='fixed-source pure ingress fixture only',oldA55HOLDUnchanged=True,productionAuthorityExecuted=False)
