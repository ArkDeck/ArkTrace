"""Pure terminal consistency checks. These never grant kernel authority."""
METRIC_KEYS=('cancelMeasured','cancelCalls','cancelToJoinedNs','joinWaitNs','joinWaitScope','withinCancelSLO')
class TerminalProofError(ValueError):pass
def require(ok,why):
 if not ok:raise TerminalProofError(why)
def cancellation(failure):
 if not isinstance(failure,dict) or failure.get('isCancellation') is not True:return False
 if failure.get('type')=='ArkTraceCore.ArkTraceError':return failure.get('code')=='CANCELLED' and failure.get('stage') in ('request','preparing','hashing','cacheLookup','parsing','validating','indexing','openingDatabase','querying','analyzing','encoding')
 if failure.get('type')=='ArkTraceRustRuntime.RustAdmission':return failure.get('code')=='9' and failure.get('stage') is None
 return failure.get('type') in ('Swift.CancellationError','_Concurrency.CancellationError') and failure.get('code') is None and failure.get('stage') is None

def validate_join(returned,joined,cancel_before,cancel_after):
 require(returned is not None,'missing open.returned')
 require(joined['success']==returned['success'],'joined/returned success mismatch')
 if returned['success']:
  require(joined.get('unexpectedSuccess') is True and 'failure' not in joined,'success join shape')
 else:
  require(joined.get('failure')==returned['failure'] and 'failure' in joined and 'unexpectedSuccess' not in joined,'joined failure not bound to returned')
  require(joined.get('cancelSLOMilliseconds')==1000,'cancel SLO contract')
 calls=1 if cancel_before is not None else 0
 require(joined['cancelCalls']==calls and (calls==0 or cancel_after is not None),'joined call count/pair mismatch')
 measured=cancel_before is not None and cancel_before['measuredGate'] is True
 require(joined['cancelMeasured']==measured,'joined measurement mismatch')
 if calls:
  require(cancel_before['cancelCalls']==cancel_after['cancelCalls']==1 and cancel_before['callMonotonicNs']==cancel_after['callMonotonicNs'],'cancel pair')
 if measured:
  start=cancel_before['callMonotonicNs'];end=joined['joinedMonotonicNs']
  require(end>=start and joined['cancelToJoinedNs']==end-start,'joined duration binding')
  require(joined['withinCancelSLO']==(joined['cancelToJoinedNs']<=1_000_000_000),'joined SLO binding')
 else:require(joined['cancelToJoinedNs'] is None and joined['withinCancelSLO'] is None,'unmeasured join metric')


def validate_result(returned,joined,result,cancel_before,cancel_after,shutdown_joined,cleanup_joined,consumer_failed=False):
 require(joined is not None,'missing open.joined')
 validate_join(returned,joined,cancel_before,cancel_after)
 require(all(result[k]==joined[k] for k in METRIC_KEYS),'result/joined metrics mismatch')
 require(result['normalShutdownJoined'] is True and shutdown_joined and cleanup_joined and not consumer_failed,'missing/failed shutdown or cleanup')
 if result['passed']:
  require(result['cancelMeasured'] is True and result['cancelCalls']==1 and result['withinCancelSLO'] is True,'passed without measured in-SLO cancellation')
  require(returned['success'] is False and joined['success'] is False and cancellation(returned['failure']),'passed without matching typed cancellation failure')
 return True
