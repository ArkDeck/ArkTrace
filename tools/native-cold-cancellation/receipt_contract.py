"""Pure bounded schema1 fact consumer for the exact A54 interactive receipt.
No IO/JSON/transport/kernel/decoder/authorization. Caller supplies one original
validation deadline and trusted nonblocking exact-bool cancellation callback.
Historical producer clocks/PIDs/close probes remain observations, never fresh proof.
"""
from dataclasses import dataclass
from enum import Enum
from typing import ClassVar
import time

class ValidationCode(str,Enum):
    INVALID_CONTROL='RECEIPT_INVALID_CONTROL'
    CANCELLED='RECEIPT_CANCELLED'
    DEADLINE='RECEIPT_DEADLINE_EXCEEDED'
    SHAPE='RECEIPT_SHAPE_INVALID'
    FIELDS='RECEIPT_FIELDS_INVALID'
    TYPE='RECEIPT_TYPE_INVALID'
    RANGE='RECEIPT_RANGE_INVALID'
    ENUM='RECEIPT_ENUM_INVALID'
    RELATION='RECEIPT_RELATION_INVALID'
    RESOURCE='RECEIPT_RESOURCE_INVALID'
    CONTROL='RECEIPT_CONTROL_ORDER_INVALID'

class ReceiptValidationError(ValueError):
    schema_version=1
    def __init__(self,code):
        self.code=code.value
        super().__init__(self.code)

class TransportCode(str,Enum):
    CALLBACK_FAILED='TRANSPORT_CALLBACK_FAILED'
    CHILD_NONZERO='TRANSPORT_CHILD_EXIT_NONZERO'
    CHILD_UNJOINED='TRANSPORT_CHILD_UNJOINED'
    CLOSE_UNPROVEN='TRANSPORT_CLOSE_UNPROVEN'
    CONTROL_CAP='TRANSPORT_CONTROL_CAP_EXCEEDED'
    CONTROL_CLOSED='TRANSPORT_CONTROL_CLOSED'
    CONTROL_NONCE='TRANSPORT_CONTROL_NONCE_INVALID'
    CONTROL_ORDER='TRANSPORT_CONTROL_ORDER_INVALID'
    DEADLINE_EXCEEDED='TRANSPORT_DEADLINE_EXCEEDED'
    DEADLINE_EXPIRED='TRANSPORT_DEADLINE_EXPIRED'
    INVALID_CONFIGURATION='TRANSPORT_INVALID_CONFIGURATION'
    INVALID_PATH='TRANSPORT_INVALID_PATH'
    IO_FAILED='TRANSPORT_IO_FAILED'
    LOG_EXISTS='TRANSPORT_LOG_EXISTS'
    RESOURCE_SETUP='TRANSPORT_RESOURCE_SETUP_FAILED'
    SPAWN_FAILED='TRANSPORT_SPAWN_FAILED'
    STDERR_LIMIT='TRANSPORT_STDERR_LIMIT_EXCEEDED'
    STDOUT_LIMIT='TRANSPORT_STDOUT_LIMIT_EXCEEDED'

class ResourceName(str,Enum):
    DIRECTORY='directory'
    STDOUT_LOG='stdoutLog'
    STDERR_LOG='stderrLog'
    SELECTOR='selector'
    STDIN='stdin'
    STDOUT='stdout'
    STDERR='stderr'

class ControlKind(str,Enum):
    CALIBRATE='calibrate'
    START='start'
    CANCEL='cancel'
    JOIN='join'
    CLEANUP='cleanup'

@dataclass(frozen=True,slots=True)
class ControlFact:
    kind:ControlKind
    wireBytes:int

@dataclass(frozen=True,slots=True)
class ClosureFact:
    resource:ResourceName
    descriptor:int | None
    objectType:str
    samePID:int
    actualCloseSucceeded:bool
    ownerObjectAndFDMatchedBeforeClose:bool
    freshKnownFDProbe:bool
    fstatReturn:int | None
    fstatErrnoEBADF:int | None
    fcntlReturn:int | None
    fcntlErrnoEBADF:int | None
    closedEBADF:bool
    producerIndex:int

@dataclass(frozen=True,slots=True)
class InteractiveReceipt:
    schemaVersion: int
    passed: bool
    code: TransportCode | None
    firstErrorCode: TransportCode | None
    startMonotonicNs: int
    endMonotonicNs: int
    absoluteDeadlineMonotonicNs: int
    deadlineExceeded: bool
    actualPopenPID: int | None
    spawnStartedMonotonicNs: int | None
    spawnReturnedMonotonicNs: int | None
    directNaturalWaitAttempted: bool
    waitStartMonotonicNs: int | None
    waitEndMonotonicNs: int | None
    actualWaitResult: int | None
    waitTimedOut: bool
    directChildReaped: bool
    liveUnjoinedRejected: bool
    stdoutActualReadBytes: int
    stderrActualReadBytes: int
    stdoutRetainedBytes: int
    stderrRetainedBytes: int
    stdoutDeclaredLimit: int
    stderrDeclaredLimit: int
    readCalls: int
    explicitReadBytes: int
    explicitWriteBytes: int
    maximumReadQuantum: int
    maximumWriteQuantum: int
    stdinAcceptedBytes: int
    stdinActualWrittenBytes: int
    controlCommands: tuple[ControlFact, ...]
    controlPendingBytesAtEnd: int
    callbackInvocations: int
    stdoutCallbackOfferedBytes: int
    closureReadbacks: tuple[ClosureFact, ...]
    allObservedOwnedFDClosesProven: bool
    observedOwnedResourceCount: int
    sentSignalCalls: int
    terminalCommandGeneratedByTransport: bool
    nonceDerivedFromStdout: bool
    implicitSpawnOSIO: str
    completeFDOrMemoryPeak: str
    grantsFreshKernelAuthority:ClassVar[bool]=False
    grantsProductCancelAuthority:ClassVar[bool]=False

TOP_SPECS=(('schemaVersion', 'int', 1, 1), ('passed', 'bool', 0, 0), ('code', 'code', 0, 64), ('firstErrorCode', 'code', 0, 64), ('startMonotonicNs', 'int', 0, 9223372036854775807), ('endMonotonicNs', 'int', 0, 9223372036854775807), ('absoluteDeadlineMonotonicNs', 'int', 1, 9223372036854775807), ('deadlineExceeded', 'bool', 0, 0), ('actualPopenPID', 'nullable_int', 1, 2147483647), ('spawnStartedMonotonicNs', 'nullable_int', 0, 9223372036854775807), ('spawnReturnedMonotonicNs', 'nullable_int', 0, 9223372036854775807), ('directNaturalWaitAttempted', 'bool', 0, 0), ('waitStartMonotonicNs', 'nullable_int', 0, 9223372036854775807), ('waitEndMonotonicNs', 'nullable_int', 0, 9223372036854775807), ('actualWaitResult', 'nullable_int', -2147483648, 2147483647), ('waitTimedOut', 'bool', 0, 0), ('directChildReaped', 'bool', 0, 0), ('liveUnjoinedRejected', 'bool', 0, 0), ('stdoutActualReadBytes', 'int', 0, 131073), ('stderrActualReadBytes', 'int', 0, 8193), ('stdoutRetainedBytes', 'int', 0, 131072), ('stderrRetainedBytes', 'int', 0, 8192), ('stdoutDeclaredLimit', 'int', 1, 131072), ('stderrDeclaredLimit', 'int', 1, 8192), ('readCalls', 'int', 0, 139268), ('explicitReadBytes', 'int', 0, 139266), ('explicitWriteBytes', 'int', 0, 139520), ('maximumReadQuantum', 'int', 0, 8192), ('maximumWriteQuantum', 'int', 0, 8192), ('stdinAcceptedBytes', 'int', 0, 256), ('stdinActualWrittenBytes', 'int', 0, 256), ('controlCommands', 'control_list', 0, 3), ('controlPendingBytesAtEnd', 'int', 0, 256), ('callbackInvocations', 'int', 0, 9223372036854775807), ('stdoutCallbackOfferedBytes', 'int', 0, 131072), ('closureReadbacks', 'closure_list', 0, 7), ('allObservedOwnedFDClosesProven', 'bool', 0, 0), ('observedOwnedResourceCount', 'int', 0, 7), ('sentSignalCalls', 'int', 0, 0), ('terminalCommandGeneratedByTransport', 'bool', 0, 0), ('nonceDerivedFromStdout', 'bool', 0, 0), ('implicitSpawnOSIO', 'unknown', 0, 7), ('completeFDOrMemoryPeak', 'unknown', 0, 7))
TOP_NAMES=tuple(x[0] for x in TOP_SPECS)
CONTROL_NAMES=('kind','wireBytes')
CLOSURE_NAMES=('resource','descriptor','objectType','samePID','actualCloseSucceeded',
 'ownerObjectAndFDMatchedBeforeClose','freshKnownFDProbe','fstatReturn','fstatErrnoEBADF',
 'fcntlReturn','fcntlErrnoEBADF','closedEBADF')
RESOURCE_NAMES=tuple(x.value for x in ResourceName)
CODE_VALUES=frozenset(x.value for x in TransportCode)
CONTROL_VALUES=frozenset(x.value for x in ControlKind)

class _Checks:
    __slots__=('deadline','cancelled')
    def __init__(self,deadline,cancelled):
        if type(deadline) is not int or not 1<=deadline<=(1<<63)-1 or not callable(cancelled):
            raise ReceiptValidationError(ValidationCode.INVALID_CONTROL)
        self.deadline=deadline;self.cancelled=cancelled
    def checkpoint(self):
        if time.monotonic_ns()>=self.deadline:raise ReceiptValidationError(ValidationCode.DEADLINE)
        try:value=self.cancelled()
        except BaseException:raise ReceiptValidationError(ValidationCode.INVALID_CONTROL) from None
        if type(value) is not bool:raise ReceiptValidationError(ValidationCode.INVALID_CONTROL)
        if value:raise ReceiptValidationError(ValidationCode.CANCELLED)
        if time.monotonic_ns()>=self.deadline:raise ReceiptValidationError(ValidationCode.DEADLINE)
    def require(self,ok,code=ValidationCode.RELATION):
        self.checkpoint()
        if not ok:raise ReceiptValidationError(code)


def _integer(value,lower,upper,nullable=False):
    if nullable and value is None:return
    if type(value) is not int:raise ReceiptValidationError(ValidationCode.TYPE)
    if value.bit_length()>64 or not lower<=value<=upper:raise ReceiptValidationError(ValidationCode.RANGE)


def _fields(value,names,checks):
    checks.checkpoint()
    if type(value) is not dict:raise ReceiptValidationError(ValidationCode.SHAPE)
    if len(value)!=len(names):raise ReceiptValidationError(ValidationCode.FIELDS)
    for key in value:
        checks.checkpoint()
        if type(key) is not str or len(key)>64 or key not in names:
            raise ReceiptValidationError(ValidationCode.FIELDS)


def _scalar(value,kind,lower,upper):
    if kind=='bool':
        if type(value) is not bool:raise ReceiptValidationError(ValidationCode.TYPE)
    elif kind in ('int','nullable_int'):_integer(value,lower,upper,kind=='nullable_int')
    elif kind=='code':
        if value is None:return
        if type(value) is not str:raise ReceiptValidationError(ValidationCode.TYPE)
        if len(value)>upper:raise ReceiptValidationError(ValidationCode.RANGE)
        if value not in CODE_VALUES:raise ReceiptValidationError(ValidationCode.ENUM)
    elif kind=='unknown':
        if type(value) is not str:raise ReceiptValidationError(ValidationCode.TYPE)
        if len(value)>upper:raise ReceiptValidationError(ValidationCode.RANGE)
        if value!='unknown':raise ReceiptValidationError(ValidationCode.ENUM)
    elif kind in ('control_list','closure_list'):
        if type(value) is not list:raise ReceiptValidationError(ValidationCode.TYPE)
        if not lower<=len(value)<=upper:raise ReceiptValidationError(ValidationCode.RANGE)
    else:raise AssertionError('fixed internal spec')


def _preflight(receipt,checks):
    # No recursive walk, input clone, sorting or JSON. Each exact built-in is
    # checked before any of its methods or content are inspected.
    _fields(receipt,TOP_NAMES,checks)
    for name,kind,lower,upper in TOP_SPECS:
        checks.checkpoint();_scalar(receipt[name],kind,lower,upper)
    for index in range(len(receipt['controlCommands'])):
        checks.checkpoint();row=receipt['controlCommands'][index];_fields(row,CONTROL_NAMES,checks)
        checks.checkpoint();kind=row['kind']
        if type(kind) is not str:raise ReceiptValidationError(ValidationCode.TYPE)
        if len(kind)>16:raise ReceiptValidationError(ValidationCode.RANGE)
        if kind not in CONTROL_VALUES:raise ReceiptValidationError(ValidationCode.ENUM)
        checks.checkpoint();_integer(row['wireBytes'],1,256)
    for index in range(len(receipt['closureReadbacks'])):
        checks.checkpoint();row=receipt['closureReadbacks'][index];_fields(row,CLOSURE_NAMES,checks)
        for name in CLOSURE_NAMES:
            checks.checkpoint();value=row[name]
            if name=='resource':
                if type(value) is not str:raise ReceiptValidationError(ValidationCode.TYPE)
                if len(value)>16:raise ReceiptValidationError(ValidationCode.RANGE)
                if value not in RESOURCE_NAMES:raise ReceiptValidationError(ValidationCode.RESOURCE)
            elif name=='descriptor':_integer(value,0,(1<<31)-1,True)
            elif name=='samePID':_integer(value,1,(1<<31)-1)
            elif name=='objectType':
                if type(value) is not str:raise ReceiptValidationError(ValidationCode.TYPE)
                if not 1<=len(value)<=128:raise ReceiptValidationError(ValidationCode.RANGE)
                if not value.isidentifier():raise ReceiptValidationError(ValidationCode.ENUM)
            elif name in ('fstatReturn','fcntlReturn'):
                _integer(value,-1,0,True)
            elif name in ('fstatErrnoEBADF','fcntlErrnoEBADF'):
                _integer(value,9,9,True)
            elif type(value) is not bool:raise ReceiptValidationError(ValidationCode.TYPE)


def _relationships(r,c):
    c.require(r['startMonotonicNs']<=r['endMonotonicNs'])
    c.require(r['deadlineExceeded']==(r['endMonotonicNs']>=r['absoluteDeadlineMonotonicNs']))
    pid=r['actualPopenPID'];wait=r['actualWaitResult'];reaped=wait is not None
    c.require(r['directChildReaped']==reaped)
    c.require(r['liveUnjoinedRejected']==(pid is not None and not reaped))
    c.require(r['directNaturalWaitAttempted']==(r['waitStartMonotonicNs'] is not None))
    if pid is None:
        c.require(wait is None and r['spawnReturnedMonotonicNs'] is None and not r['directNaturalWaitAttempted'] and r['waitEndMonotonicNs'] is None)
    else:
        c.require(r['spawnStartedMonotonicNs'] is not None and r['spawnReturnedMonotonicNs'] is not None and r['directNaturalWaitAttempted'] and r['waitEndMonotonicNs'] is not None)
    spawn_start=r['spawnStartedMonotonicNs'];spawn_return=r['spawnReturnedMonotonicNs']
    if spawn_start is not None:c.require(r['startMonotonicNs']<=spawn_start<=r['endMonotonicNs'])
    if spawn_return is not None:c.require(spawn_start<=spawn_return<=r['endMonotonicNs'])
    if r['directNaturalWaitAttempted']:
        c.require(spawn_return<=r['waitStartMonotonicNs']<=r['waitEndMonotonicNs']<=r['endMonotonicNs'])
    else:c.require(r['waitEndMonotonicNs'] is None)
    c.require(not r['waitTimedOut'] or pid is not None and not reaped)
    if wait is not None and wait!=0:c.require(r['firstErrorCode'] is not None)
    if r['firstErrorCode']==TransportCode.CHILD_NONZERO.value:c.require(reaped and wait!=0)
    if r['firstErrorCode']==TransportCode.CHILD_UNJOINED.value:c.require(pid is not None and not reaped)
    code=TransportCode.CHILD_UNJOINED.value if pid is not None and not reaped else r['firstErrorCode']
    if not r['allObservedOwnedFDClosesProven'] and code is None:code=TransportCode.CLOSE_UNPROVEN.value
    if r['deadlineExceeded'] and code is None:code=TransportCode.DEADLINE_EXCEEDED.value
    c.require(r['code']==code)
    c.require(code is not None or reaped and wait==0)
    c.require(r['passed']==(code is None and reaped and wait==0))
    c.require(r['stdoutActualReadBytes']<=r['stdoutDeclaredLimit']+1 and r['stderrActualReadBytes']<=r['stderrDeclaredLimit']+1)
    if r['stdoutActualReadBytes']>r['stdoutDeclaredLimit'] or r['stderrActualReadBytes']>r['stderrDeclaredLimit']:c.require(r['firstErrorCode'] is not None)
    c.require(r['stdoutRetainedBytes']<=min(r['stdoutDeclaredLimit'],r['stdoutActualReadBytes']) and r['stderrRetainedBytes']<=min(r['stderrDeclaredLimit'],r['stderrActualReadBytes']))
    c.require(r['explicitReadBytes']==r['stdoutActualReadBytes']+r['stderrActualReadBytes'])
    c.require(r['explicitWriteBytes']==r['stdoutRetainedBytes']+r['stderrRetainedBytes']+r['stdinActualWrittenBytes'])
    c.require(r['stdoutCallbackOfferedBytes']<=r['stdoutRetainedBytes'])
    c.require(r['readCalls']<=r['explicitReadBytes']+2)
    c.require(r['explicitReadBytes']==0 or r['readCalls']>0 and r['maximumReadQuantum']>0)
    c.require(not r['terminalCommandGeneratedByTransport'] and not r['nonceDerivedFromStdout'])
    wire=0
    for index,row in enumerate(r['controlCommands']):
        c.checkpoint();kind=row['kind']
        expected=kind=='calibrate' if index==0 else kind=='start' if index==1 else kind in ('cancel','join','cleanup')
        c.require(expected,ValidationCode.CONTROL)
        c.require(row['wireBytes']==len(kind)+38)
        wire+=row['wireBytes']
    c.require(wire==r['stdinAcceptedBytes'])
    c.require(r['stdinActualWrittenBytes']<=wire and r['controlPendingBytesAtEnd']==wire-r['stdinActualWrittenBytes'])
    seen=0;same_pid=None;all_closed=True
    for row in r['closureReadbacks']:
        c.checkpoint();bit=1<<RESOURCE_NAMES.index(row['resource'])
        c.require(not seen&bit,ValidationCode.RESOURCE);seen|=bit
        if same_pid is None:same_pid=row['samePID']
        else:c.require(row['samePID']==same_pid)
        succeeded=row['actualCloseSucceeded'];owned=row['ownerObjectAndFDMatchedBeforeClose'];probe=row['freshKnownFDProbe']
        c.require(not succeeded or owned)
        c.require(not probe or succeeded and owned and row['descriptor'] is not None)
        if not probe:c.require(all(row[name] is None for name in ('fstatReturn','fstatErrnoEBADF','fcntlReturn','fcntlErrnoEBADF')))
        for method in ('fstat','fcntl'):
            c.checkpoint();returned=row[method+'Return'];err=row[method+'ErrnoEBADF']
            c.require(err is None or returned==-1)
        closed=succeeded and owned and probe and row['fstatReturn']==row['fcntlReturn']==-1 and row['fstatErrnoEBADF']==row['fcntlErrnoEBADF']==9
        c.require(row['closedEBADF']==closed);all_closed=all_closed and closed
    c.require(r['observedOwnedResourceCount']==len(r['closureReadbacks']))
    c.require(r['allObservedOwnedFDClosesProven']==all_closed)


def validate_interactive_receipt(receipt,*,absolute_deadline_ns,cancelled):
    """Validate schema1 shape/finite relationships and preserve historical facts.

    No fresh close/wait/identity or product authority is inferred. Unobserved
    resources stay absent; a true allObserved flag on an empty tuple is retained.
    Closure DTOs use ResourceName order, with producerIndex retaining source order.
    The actual validation deadline is independent of historical receipt clocks.
    """
    checks=_Checks(absolute_deadline_ns,cancelled);checks.checkpoint()
    _preflight(receipt,checks);checks.checkpoint();_relationships(receipt,checks)
    # Only now is any input copied or canonicalized into typed immutable facts.
    controls=[]
    for row in receipt['controlCommands']:
        checks.checkpoint();controls.append(ControlFact(ControlKind(row['kind']),row['wireBytes']))
    closures={}
    for index,row in enumerate(receipt['closureReadbacks']):
        checks.checkpoint();values={name:row[name] for name in CLOSURE_NAMES}
        values['resource']=ResourceName(row['resource']);values['producerIndex']=index
        closures[row['resource']]=ClosureFact(**values)
    canonical=[]
    for name in RESOURCE_NAMES:
        checks.checkpoint()
        if name in closures:canonical.append(closures[name])
    values={}
    for name in TOP_NAMES:
        checks.checkpoint()
        if name=='controlCommands':value=tuple(controls)
        elif name=='closureReadbacks':value=tuple(canonical)
        elif name in ('code','firstErrorCode'):value=None if receipt[name] is None else TransportCode(receipt[name])
        else:value=receipt[name]
        values[name]=value
    result=InteractiveReceipt(**values);checks.checkpoint();return result
