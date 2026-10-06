"""Bounded v2 protocol decoder; stdout never authenticates kernel ownership."""
import json,math,time,uuid
from wire_preflight import WireBudget,WireError,CODES as WIRE_CODES
from ownership import KernelOwnership
from terminal_proof import validate_join,validate_result,TerminalProofError
STAGES=('preparing','hashing','cacheLookup','parsing','validating','indexing','openingDatabase','ready','failed','cancelled')
CLOCK='Swift.DispatchTime.uptimeNanoseconds'
ENVELOPE={'schemaVersion','sequence','event','clockID','monotonicNs','controlNonce'}
METRICS={'cancelCalls','cancelMeasured','cancelToJoinedNs','joinWaitNs','joinWaitScope','withinCancelSLO'}
FIELDS={
 'consumer.bootstrap':{'pid','parentPID','normalPublicSDK','storagePolicy'},'clock.calibration':set(),
 'engine.create.before':set(),'engine.create.joined':set(),'open.before':{'timeoutMilliseconds','openTasks'},
 'open.progress':{'stage'},'open.returned':{'success','failure'},
 'cancel.before':{'callMonotonicNs','measuredGate','cancelCalls','mode'},'cancel.after':{'callMonotonicNs','cancelCalls'},
 'open.joined':{'success','joinedMonotonicNs'}|METRICS,
 'unexpectedSession.close.before':set(),'unexpectedSession.close.joined':set(),
 'retained.beforeShutdown':{'bytes'},'engine.shutdown.before':set(),'engine.shutdown.joined':set(),
 'engine.shutdown.failure':{'failure'},'cleanup.flush.joined':set(),'consumer.failure':{'failure'},
 'consumer.result':{'passed','cancelCalls','normalShutdownJoined','privateRequestCounts','privateColdCounts','descendantActualExitCodes','descendantWaitReaped','completeProcessForestProven'}|METRICS,
 'protocol.guard.before':set(),'protocol.guard.joinOnly':METRICS,'protocol.guard.unmeasuredCleanup':METRICS,
 'protocol.guard.inputCase':{'name','passed','expectedSuccess','rejected','openedDescriptors','closedDescriptors','allClosedEBADF','returnedBytes'},
 'protocol.guard.inputResult':{'passed','caseCount','engineCreateCalls','openCalls','cancelCalls'},
 'protocol.guard.result':{'passed','caseCount','engineCreateCalls','openCalls','cancelCalls','actualCancellationValidated'}}
OPTIONAL={'open.joined':{'unexpectedSuccess','failure','cancelSLOMilliseconds'},'retained.beforeShutdown':{'scope','privateColdCounts','privateRegistryCounts','failure'},'engine.shutdown.joined':{'postShutdownHandleQueryExecuted'}}
ERROR_CODES=WIRE_CODES|frozenset(('semantic_invalid','duplicate_key','nonfinite_json','decoder_invalid','json_invalid','json_recursion','incomplete_terminal','nonce_invalid','mode_invalid'))
LEGACY_CODES={'duplicate JSON key':'duplicate_key','nonfinite JSON':'nonfinite_json','decoder closed/rejected':'decoder_invalid','rejected stream':'decoder_invalid','incomplete terminal proof':'incomplete_terminal','canonical UUID nonce':'nonce_invalid','mode':'mode_invalid'}
class ProtocolError(ValueError):
 def __init__(self,code):
  self.code=code if code in ERROR_CODES else LEGACY_CODES.get(code,'semantic_invalid');super().__init__(self.code)
def canonical_nonce(nonce):
 if type(nonce) is not str or len(nonce)!=36:return False
 try:return str(uuid.UUID(nonce))==nonce
 except (ValueError,TypeError,AttributeError):return False
def require(ok,why):
 if not ok:raise ProtocolError(why)
def uint(x):return type(x) is int and 0<=x<=2**64-1
def boolean(x):return type(x) is bool
def nullable_string(x):return x is None or (type(x) is str and 0<len(x)<=512)
def failure(x):
 require(type(x) is dict and set(x)=={'type','code','stage','isCancellation'},'failure shape')
 require(type(x['type']) is str and 0<len(x['type'])<=512 and nullable_string(x['code']) and nullable_string(x['stage']) and boolean(x['isCancellation']),'failure types')
def unique_pairs(pairs):
 result={}
 for k,v in pairs:
  require(k not in result,'duplicate JSON key');result[k]=v
 return result
class Decoder:
 def __init__(self,nonce,mode='normal',*,absolute_deadline_ns,cancelled):
  try:self._wire=WireBudget(absolute_deadline_ns,cancelled)
  except WireError as error:raise ProtocolError(error.code) from None
  require(canonical_nonce(nonce),'canonical UUID nonce')
  require(mode in ('normal','guard'),'mode');self.nonce=nonce;self.mode=mode;self.seq=0;self.clock=-1;self.bytes=0;self.seen=set();self.stage=None;self.terminal=False;self.invalid=False;self.cancel_start=None;self.measured=False;self.cancel_authorized=False;self.last_progress_received=None;self.closed=False;self.returned=None;self.joined=None;self.cancel_before=None;self.cancel_after=None;self.consumer_failed=False;self.shutdown_failed=False
 def feed(self,line):
  try:
   require(not self.invalid and not self.closed,'decoder closed/rejected')
   self._wire.check();result=self._feed(line);self._wire.check();return result
  except (WireError,ProtocolError) as error:
   self.invalid=True;raise ProtocolError(error.code) from None
  except RecursionError:
   self.invalid=True;raise ProtocolError('json_recursion') from None
  except TerminalProofError:
   self.invalid=True;raise ProtocolError('semantic_invalid') from None
  except (ValueError,TypeError,UnicodeError,OverflowError):
   self.invalid=True;raise ProtocolError('json_invalid') from None
 def _feed(self,line):
  require(not self.invalid and not self.closed,'decoder closed/rejected')
  require(type(line) is bytes and 0<len(line)<=65536,'record cap/type');require(self.bytes+len(line)<=131072,'stream cap')
  self._wire.scan(line)
  x=json.loads(line,object_pairs_hook=unique_pairs,parse_constant=lambda _:(_ for _ in ()).throw(ProtocolError('nonfinite JSON')))
  self._wire.check_decoded(x)
  require(type(x) is dict and ENVELOPE<=set(x),'envelope')
  event=x['event'];require(type(event) is str and event in FIELDS,'unknown event')
  require(set(x)>=ENVELOPE|FIELDS[event] and set(x)<=ENVELOPE|FIELDS[event]|OPTIONAL.get(event,set()),'event fields')
  require(type(x['schemaVersion']) is int and x['schemaVersion']==3,'schema version')
  require(uint(x['sequence']) and x['sequence']==self.seq+1,'duplicate/skipped sequence')
  require(type(x['clockID']) is str and x['clockID']==CLOCK and uint(x['monotonicNs']) and x['monotonicNs']>=self.clock,'clock')
  require(type(x['controlNonce']) is str and x['controlNonce']==self.nonce,'nonce')
  require(event in ('open.progress','protocol.guard.inputCase') or event not in self.seen,'duplicate singleton event')
  require(event.startswith('protocol.guard.')== (self.mode=='guard') or event in ('open.progress','open.returned'),'mode/event')
  if self.seq==0:require(event==('consumer.bootstrap' if self.mode=='normal' else 'protocol.guard.before'),'initial event')
  for k in ('success','unexpectedSuccess','normalPublicSDK','measuredGate','passed','normalShutdownJoined','completeProcessForestProven','postShutdownHandleQueryExecuted','actualCancellationValidated','expectedSuccess','rejected','allClosedEBADF'):
   if k in x:require(boolean(x[k]),k+' bool')
  for k in ('pid','parentPID','timeoutMilliseconds','openTasks','callMonotonicNs','cancelCalls','joinedMonotonicNs','cancelSLOMilliseconds','caseCount','engineCreateCalls','openCalls','openedDescriptors','closedDescriptors'):
   if k in x:require(uint(x[k]),k+' uint')
  if 'failure' in x and x['failure'] is not None:failure(x['failure'])
  if event=='consumer.bootstrap':require(x['pid']>0 and x['parentPID']>0 and x['normalPublicSDK'] is True and x['storagePolicy']=='ephemeral','bootstrap')
  predecessors={'clock.calibration':'consumer.bootstrap','engine.create.before':'clock.calibration','engine.create.joined':'engine.create.before','open.before':'engine.create.joined','cancel.after':'cancel.before','cancel.before':'open.before','open.joined':'open.returned','retained.beforeShutdown':'open.joined','engine.shutdown.failure':'engine.shutdown.before','unexpectedSession.close.before':'open.joined','unexpectedSession.close.joined':'unexpectedSession.close.before','engine.shutdown.joined':'engine.shutdown.before','cleanup.flush.joined':'engine.shutdown.joined','consumer.result':'cleanup.flush.joined'}
  if event in predecessors:require(predecessors[event] in self.seen,'event order')
  if event in ('open.progress','open.returned'):
   require(('open.before' if self.mode=='normal' else 'protocol.guard.before') in self.seen and not self.terminal,'progress/return lifecycle')
  if event=='open.progress':
   require(type(x['stage']) is str and x['stage'] in STAGES,'typed public stage');self.stage=x['stage'];self.last_progress_received=time.monotonic_ns()
  if event=='open.returned':
   require(x['success']==(x['failure'] is None),'terminal result');self.terminal=True
  if event=='cancel.before':
   require('open.joined' not in self.seen and (not x['measuredGate'] or not self.terminal),'cancel after terminal/join')
   require(not x['measuredGate'] or self.cancel_authorized,'stdout cannot authorize measured cancel')
   require(x['cancelCalls']==1 and x['mode']==('observedParsingAndParentHandshake' if x['measuredGate'] else 'unmeasuredCleanup'),'cancel mode');self.cancel_start=x['callMonotonicNs'];self.measured=x['measuredGate']
   require(self.cancel_start<=x['monotonicNs'],'call clock')
  if event=='cancel.after':
   require('open.joined' not in self.seen,'cancel.after after join')
   require(x['cancelCalls']==1 and x['callMonotonicNs']==self.cancel_start,'cancel pairing')
  if 'bytes' in x:require(x['bytes'] is None or uint(x['bytes']),'retained bytes')
  for k in ('privateColdCounts','privateRegistryCounts','privateRequestCounts','descendantActualExitCodes','descendantWaitReaped'):
   if k in x:require(x[k] is None,'unsupported private proof')
  if METRICS<=set(x):
   require(boolean(x['cancelMeasured']),'measured bool')
   if x['cancelMeasured']:
    require(self.mode=='normal' and self.measured and 'cancel.after' in self.seen and uint(x['cancelToJoinedNs']) and x['joinWaitNs'] is None and x['joinWaitScope'] is None and boolean(x['withinCancelSLO']),'unproven measured duration')
    require(x['withinCancelSLO']==(x['cancelToJoinedNs']<=1_000_000_000),'SLO consistency')
    if event=='open.joined':require(x['joinedMonotonicNs']>=self.cancel_start and x['cancelToJoinedNs']==x['joinedMonotonicNs']-self.cancel_start,'duration clock binding')
   else:require(x['cancelToJoinedNs'] is None and x['withinCancelSLO'] is None and uint(x['joinWaitNs']) and x['joinWaitScope']=='ordinaryJoinOrUnmeasuredCleanup','unmeasured duration must be null')
  if event=='protocol.guard.inputCase':
   require(type(x['name']) is str and 0<len(x['name'])<=64 and x['passed'] and x['rejected'] != x['expectedSuccess'] and x['openedDescriptors']==x['closedDescriptors'] and x['allClosedEBADF'] and (x['returnedBytes'] is None or uint(x['returnedBytes']) and x['returnedBytes']<=65536),'input guard proof')
  if event=='protocol.guard.inputResult':require(x['passed'] and x['caseCount']==21 and x['engineCreateCalls']==x['openCalls']==x['cancelCalls']==0,'input guard scope')
  if event=='consumer.result':require(not x['completeProcessForestProven'] and (not x['passed'] or x['cancelMeasured']),'result proof scope')
  if event=='protocol.guard.result':require(x['engineCreateCalls']==x['openCalls']==x['cancelCalls']==0 and x['actualCancellationValidated'] is False and x['caseCount']==14,'guard scope')
  if self.mode=='normal':
   require(not self.consumer_failed or event in ('engine.shutdown.before','engine.shutdown.joined','engine.shutdown.failure'),'event after consumer failure')
   if event=='open.returned':self.returned=dict(x)
   if event=='cancel.before':self.cancel_before=dict(x)
   if event=='cancel.after':self.cancel_after=dict(x)
   if event=='open.joined':
    validate_join(self.returned,x,self.cancel_before,self.cancel_after);self.joined=dict(x)
   if event in ('unexpectedSession.close.before','unexpectedSession.close.joined'):
    require(self.joined is not None and self.joined['success'],'close without successful session')
   if event=='engine.shutdown.before':
    require('engine.create.joined' in self.seen and (self.consumer_failed or self.joined is not None),'shutdown before joining open')
    if self.joined is not None and self.joined['success']:
     require('unexpectedSession.close.joined' in self.seen or self.consumer_failed,'shutdown before session close')
   if event=='engine.shutdown.joined':require(not self.shutdown_failed,'shutdown joined after failure')
   if event=='engine.shutdown.failure':self.shutdown_failed=True
   if event=='consumer.failure':self.consumer_failed=True
   if event=='consumer.result':
    validate_result(self.returned,self.joined,x,self.cancel_before,self.cancel_after,'engine.shutdown.joined' in self.seen and not self.shutdown_failed,'cleanup.flush.joined' in self.seen,self.consumer_failed);self.closed=True
  elif event=='protocol.guard.result':
   require('protocol.guard.inputResult' in self.seen and 'protocol.guard.joinOnly' in self.seen and 'protocol.guard.unmeasuredCleanup' in self.seen,'guard closure');self.closed=True
  self._wire.check()
  self.seq=x['sequence'];self.clock=x['monotonicNs'];self.bytes+=len(line);self.seen.add(event);return x
 def _checkpoint(self):
  try:
   require(not self.invalid,'rejected stream');self._wire.check()
  except (WireError,ProtocolError) as error:
   self.invalid=True;self.cancel_authorized=False
   raise ProtocolError(error.code) from None

 def _checked_result(self,result):
  self._checkpoint();return result

 def cancel_gate(self,ownership=None):
  self._checkpoint()
  if ownership is not None:require(type(ownership) is KernelOwnership,'kernel witness required')
  fresh=self.last_progress_received is not None and time.monotonic_ns()-self.last_progress_received<=100_000_000
  return self._checked_result(self.protocol_allows_cancel and fresh and ownership is not None and ownership.revalidate())

 def authorize_cancel(self,ownership):
  self._checkpoint()
  require(not self.cancel_authorized and 'cancel.before' not in self.seen and self.cancel_gate(ownership),'live parsing and independent kernel admission required')
  self.cancel_authorized=True
  return self._checked_result('cancel:'+self.nonce+'\n')

 def finish(self):
  self._checkpoint()
  if self.invalid:raise ProtocolError('rejected stream')
  if self.closed:return self._checked_result({'complete':True,'failureEvidence':False})
  if self.mode=='normal' and (self.consumer_failed or self.shutdown_failed):return self._checked_result({'complete':False,'failureEvidence':True})
  raise ProtocolError('incomplete terminal proof')

 @property
 def protocol_allows_cancel(self):
  return self.mode=='normal' and not self.invalid and not self.closed and not self.consumer_failed and not self.shutdown_failed and not self.terminal and self.stage=='parsing' and 'clock.calibration' in self.seen
