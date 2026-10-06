"""Bounded direct-child byte transport. No protocol decoder or authorization.

Trusted callbacks must be nonblocking and return None. They receive the actual
direct Popen handle for caller-owned admission, plus a bounded control sender.
This module has no signal authority. A live/unjoined handle is returned to the
caller with a rejected result; caller cleanup/admission is a separate contract.
"""
from dataclasses import dataclass,field
from enum import Enum
import errno
import fcntl
import os
from pathlib import Path
import selectors
import stat
import subprocess
import time
import uuid

QUANTUM=8192
STDIN_CAP=256
STDOUT_CAP=131072
STDERR_CAP=8192

class Code(str,Enum):
    INVALID_CONFIGURATION='TRANSPORT_INVALID_CONFIGURATION'
    INVALID_PATH='TRANSPORT_INVALID_PATH'
    DEADLINE_EXPIRED='TRANSPORT_DEADLINE_EXPIRED'
    DEADLINE_EXCEEDED='TRANSPORT_DEADLINE_EXCEEDED'
    LOG_EXISTS='TRANSPORT_LOG_EXISTS'
    RESOURCE_SETUP='TRANSPORT_RESOURCE_SETUP_FAILED'
    SPAWN_FAILED='TRANSPORT_SPAWN_FAILED'
    IO_FAILED='TRANSPORT_IO_FAILED'
    STDOUT_LIMIT='TRANSPORT_STDOUT_LIMIT_EXCEEDED'
    STDERR_LIMIT='TRANSPORT_STDERR_LIMIT_EXCEEDED'
    CALLBACK_FAILED='TRANSPORT_CALLBACK_FAILED'
    CONTROL_NONCE='TRANSPORT_CONTROL_NONCE_INVALID'
    CONTROL_ORDER='TRANSPORT_CONTROL_ORDER_INVALID'
    CONTROL_CAP='TRANSPORT_CONTROL_CAP_EXCEEDED'
    CONTROL_CLOSED='TRANSPORT_CONTROL_CLOSED'
    CHILD_NONZERO='TRANSPORT_CHILD_EXIT_NONZERO'
    CHILD_UNJOINED='TRANSPORT_CHILD_UNJOINED'
    CLOSE_UNPROVEN='TRANSPORT_CLOSE_UNPROVEN'

class TransportError(ValueError):
    schema_version=1
    def __init__(self,code):
        assert type(code) is Code
        self.code=code.value
        super().__init__(self.code)

def _integer(value,lo,hi):
    if type(value) is not int or not lo<=value<=hi:raise TransportError(Code.INVALID_CONFIGURATION)

def _text(value,allow_empty=True):
    if type(value) is not str or '\0' in value or (not allow_empty and not value):raise TransportError(Code.INVALID_CONFIGURATION)
    try:encoded=value.encode('utf-8')
    except UnicodeError:raise TransportError(Code.INVALID_CONFIGURATION) from None
    if len(encoded)>4096:raise TransportError(Code.INVALID_CONFIGURATION)
    return len(encoded)

@dataclass(frozen=True,slots=True)
class Configuration:
    output_directory:str
    stem:str
    argv:tuple
    env:dict
    absolute_deadline_ns:int
    stdout_limit:int
    stderr_limit:int

def validate_configuration(output_directory,stem,argv,env,absolute_deadline_ns,stdout_limit,stderr_limit,on_stdout_bytes,on_tick):
    _integer(absolute_deadline_ns,1,(1<<63)-1)
    _integer(stdout_limit,1,STDOUT_CAP);_integer(stderr_limit,1,STDERR_CAP)
    if time.monotonic_ns()>=absolute_deadline_ns:raise TransportError(Code.DEADLINE_EXPIRED)
    if not callable(on_stdout_bytes) or not callable(on_tick):raise TransportError(Code.INVALID_CONFIGURATION)
    if type(argv) not in (list,tuple) or not 1<=len(argv)<=64:raise TransportError(Code.INVALID_CONFIGURATION)
    if sum(_text(x,False) for x in argv)>16384:raise TransportError(Code.INVALID_CONFIGURATION)
    if not os.path.isabs(argv[0]):raise TransportError(Code.INVALID_CONFIGURATION)
    if type(env) is not dict or len(env)>128:raise TransportError(Code.INVALID_CONFIGURATION)
    amount=0
    for key,value in env.items():
        amount+=_text(key,False)+_text(value)
        if '=' in key:raise TransportError(Code.INVALID_CONFIGURATION)
    if amount>16384:raise TransportError(Code.INVALID_CONFIGURATION)
    if type(stem) is not str or not 1<=len(stem)<=64 or not stem[0].isascii() or not stem[0].isalnum():raise TransportError(Code.INVALID_CONFIGURATION)
    if any(not c.isascii() or not (c.isalnum() or c in '_-') for c in stem):raise TransportError(Code.INVALID_CONFIGURATION)
    if not isinstance(output_directory,(str,Path)):raise TransportError(Code.INVALID_PATH)
    spelling=os.fspath(output_directory)
    if type(spelling) is not str or '\0' in spelling or len(spelling)>4096 or not os.path.isabs(spelling) or os.path.normpath(spelling)!=spelling:
        raise TransportError(Code.INVALID_PATH)
    try:path_bytes=len(spelling.encode('utf-8'))
    except UnicodeError:raise TransportError(Code.INVALID_PATH) from None
    if path_bytes>4096:raise TransportError(Code.INVALID_PATH)
    parts=Path(spelling).parts
    if len(parts)>256:raise TransportError(Code.INVALID_PATH)
    current=Path(parts[0])
    try:
        for index,part in enumerate(parts):
            if index:current=current/part
            if time.monotonic_ns()>=absolute_deadline_ns:raise TransportError(Code.DEADLINE_EXPIRED)
            metadata=os.lstat(current)
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):raise TransportError(Code.INVALID_PATH)
    except OSError:raise TransportError(Code.INVALID_PATH) from None
    return Configuration(spelling,stem,tuple(argv),dict(env),absolute_deadline_ns,stdout_limit,stderr_limit)

class ControlPort:
    def __init__(self,absolute_deadline_ns):
        _integer(absolute_deadline_ns,1,(1<<63)-1)
        self._deadline=absolute_deadline_ns;self._pending=bytearray();self._phase=0;self._nonce=None
        self._active=True;self._child=None;self._accepted=[];self._accepted_bytes=0;self._written=0
    @property
    def direct_child(self):return self._child
    @property
    def absolute_deadline_ns(self):return self._deadline
    def send_control(self,kind,canonical_nonce):
        if not self._active:raise TransportError(Code.CONTROL_CLOSED)
        if time.monotonic_ns()>=self._deadline:raise TransportError(Code.DEADLINE_EXCEEDED)
        if type(kind) is not str or kind not in ('calibrate','start','cancel','join','cleanup'):raise TransportError(Code.CONTROL_ORDER)
        if type(canonical_nonce) is not str or len(canonical_nonce)!=36:raise TransportError(Code.CONTROL_NONCE)
        try:canonical=str(uuid.UUID(canonical_nonce))
        except (ValueError,AttributeError):raise TransportError(Code.CONTROL_NONCE) from None
        if canonical!=canonical_nonce:raise TransportError(Code.CONTROL_NONCE)
        if self._nonce is not None and self._nonce!=canonical_nonce:raise TransportError(Code.CONTROL_NONCE)
        expected=self._phase==0 and kind=='calibrate' or self._phase==1 and kind=='start' or self._phase==2 and kind in ('cancel','join','cleanup')
        if not expected:raise TransportError(Code.CONTROL_ORDER)
        wire=(kind+':'+canonical_nonce+'\n').encode('ascii')
        if self._accepted_bytes+len(wire)>STDIN_CAP or len(self._pending)+len(wire)>STDIN_CAP:raise TransportError(Code.CONTROL_CAP)
        self._pending.extend(wire);self._accepted_bytes+=len(wire);self._phase+=1;self._nonce=canonical_nonce
        self._accepted.append(dict(kind=kind,wireBytes=len(wire)))
    def _consume(self,amount):
        if type(amount) is not int or not 0<amount<=len(self._pending):raise TransportError(Code.IO_FAILED)
        del self._pending[:amount];self._written+=amount

class _Owner:
    def __init__(self,label):self.label=label;self.obj=None;self.fd=None;self.signature=None;self.closed=False;self.close_attempted=False

class Owners:
    """Fixed resource inventory, allocated before any OS FD acquisition."""
    def __init__(self):
        self.items={name:_Owner(name) for name in ('directory','stdoutLog','stderrLog','selector','stdin','stdout','stderr')};self.receipts=[]
    def bind_fd(self,name,fd):
        owner=self.items[name];owner.fd=fd
        self.capture(name)
    def bind_object(self,name,obj):self.items[name].obj=obj
    def capture(self,name):
        owner=self.items[name]
        try:
            if owner.fd is None:owner.fd=owner.obj.fileno()
            metadata=os.fstat(owner.fd);owner.signature=(metadata.st_dev,metadata.st_ino,metadata.st_mode)
        except BaseException:raise TransportError(Code.RESOURCE_SETUP) from None
    def close(self,name):
        owner=self.items[name]
        if owner.closed or owner.close_attempted or owner.fd is None and owner.obj is None:return
        # A failed close may already have released the descriptor. Do not retry
        # it, risk a reused FD, or append unbounded duplicate resource facts.
        # Keep the failed/unknown first observation and reject closure proof.
        owner.close_attempted=True
        succeeded=False;ownership=True;probe=False;sr=fr=None;se=fe=None
        try:
            if owner.fd is not None:
                if owner.obj is not None and (getattr(owner.obj,'closed',False) or owner.obj.fileno()!=owner.fd):ownership=False
                if ownership and owner.signature is not None:
                    metadata=os.fstat(owner.fd)
                    ownership=(metadata.st_dev,metadata.st_ino,metadata.st_mode)==owner.signature
            if ownership:
                if owner.obj is not None:owner.obj.close()
                else:os.close(owner.fd)
                succeeded=True
                # No FD allocation between this actual close and both probes.
                if owner.fd is not None:
                    probe=True
                    try:os.fstat(owner.fd);sr=0
                    except OSError as error:sr=-1;se=9 if error.errno==errno.EBADF else None
                    try:fcntl.fcntl(owner.fd,fcntl.F_GETFD);fr=0
                    except OSError as error:fr=-1;fe=9 if error.errno==errno.EBADF else None
        except BaseException:pass
        owner.closed=succeeded
        self.receipts.append(dict(resource=name,descriptor=owner.fd,objectType=type(owner.obj).__name__ if owner.obj is not None else 'ownedRawFD',
            samePID=os.getpid(),actualCloseSucceeded=succeeded,ownerObjectAndFDMatchedBeforeClose=ownership,
            freshKnownFDProbe=probe,fstatReturn=sr,fstatErrnoEBADF=se,fcntlReturn=fr,fcntlErrnoEBADF=fe,
            closedEBADF=succeeded and ownership and probe and sr==fr==-1 and se==fe==9))
    def close_all(self):
        for name in ('stdin','selector','stdout','stderr','stdoutLog','stderrLog','directory'):self.close(name)

@dataclass(slots=True)
class InteractiveResult:
    receipt:dict
    direct_child:object=field(repr=False)

def run_interactive(output_directory,stem,argv,env,absolute_deadline_ns,stdout_limit,stderr_limit,on_stdout_bytes,on_tick):
    cfg=validate_configuration(output_directory,stem,argv,env,absolute_deadline_ns,stdout_limit,stderr_limit,on_stdout_bytes,on_tick)
    owners=Owners();control=ControlPort(cfg.absolute_deadline_ns);child=None;selector=None;first_error=None;wait_result=None;wait_start=None;wait_end=None;wait_timed_out=False
    observed={'stdout':0,'stderr':0};retained={'stdout':0,'stderr':0};write_bytes=0;read_calls=0;max_read=0;max_write=0
    callbacks=0;offered=0;start=time.monotonic_ns();spawn_start=None;spawn_return=None;stdin_registered=False
    def fail(code):
        nonlocal first_error
        if first_error is None:first_error=code
    def close_stdin():
        nonlocal stdin_registered
        if stdin_registered:
            try:selector.unregister(owners.items['stdin'].obj)
            except BaseException:fail(Code.RESOURCE_SETUP)
            stdin_registered=False
        owners.close('stdin');control._active=False
    def callback(fn,*args):
        nonlocal callbacks
        if time.monotonic_ns()>=cfg.absolute_deadline_ns:raise TransportError(Code.DEADLINE_EXCEEDED)
        callbacks+=1
        try:returned=fn(*args)
        except TransportError:raise
        except BaseException:raise TransportError(Code.CALLBACK_FAILED) from None
        if returned is not None:raise TransportError(Code.CALLBACK_FAILED)
        if time.monotonic_ns()>=cfg.absolute_deadline_ns:raise TransportError(Code.DEADLINE_EXCEEDED)
    try:
        directory=os.open(cfg.output_directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)
        owners.bind_fd('directory',directory)
        held=os.fstat(directory);named=os.lstat(cfg.output_directory)
        if (held.st_dev,held.st_ino,held.st_mode)!=(named.st_dev,named.st_ino,named.st_mode):raise TransportError(Code.INVALID_PATH)
        names={stream:cfg.stem+'.'+stream+'.log' for stream in ('stdout','stderr')}
        for filename in names.values():
            try:os.stat(filename,dir_fd=directory,follow_symlinks=False)
            except FileNotFoundError:continue
            raise TransportError(Code.LOG_EXISTS)
        for stream in ('stdout','stderr'):
            fd=os.open(names[stream],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=directory)
            owners.bind_fd(stream+'Log',fd)
        selector=selectors.DefaultSelector();owners.bind_object('selector',selector);owners.capture('selector')
        if time.monotonic_ns()>=cfg.absolute_deadline_ns:raise TransportError(Code.DEADLINE_EXCEEDED)
        spawn_start=time.monotonic_ns()
        try:child=subprocess.Popen(cfg.argv,env=cfg.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0,start_new_session=True,shell=False)
        except BaseException:raise TransportError(Code.SPAWN_FAILED) from None
        spawn_return=time.monotonic_ns();control._child=child
        # Own all three returned objects before any fallible fstat/register.
        for name in ('stdin','stdout','stderr'):owners.bind_object(name,getattr(child,name))
        for name in ('stdin','stdout','stderr'):
            owners.capture(name);os.set_blocking(owners.items[name].fd,False)
        for name in ('stdout','stderr'):selector.register(owners.items[name].obj,selectors.EVENT_READ,name)
        live_streams={'stdout','stderr'}
        while live_streams:
            if time.monotonic_ns()>=cfg.absolute_deadline_ns:fail(Code.DEADLINE_EXCEEDED);break
            if first_error is None:
                try:callback(on_tick,control)
                except TransportError as error:fail(Code(error.code))
            if first_error is not None and not owners.items['stdin'].closed:close_stdin()
            if control._pending and not owners.items['stdin'].closed and first_error is None and not stdin_registered:
                selector.register(owners.items['stdin'].obj,selectors.EVENT_WRITE,'stdin');stdin_registered=True
            if not control._pending and stdin_registered:
                selector.unregister(owners.items['stdin'].obj);stdin_registered=False
            if control._phase==3 and not control._pending and not owners.items['stdin'].closed:close_stdin()
            remaining=(cfg.absolute_deadline_ns-time.monotonic_ns())/1e9
            if remaining<=0:fail(Code.DEADLINE_EXCEEDED);break
            for key,_ in selector.select(min(.01,remaining)):
                name=key.data
                if time.monotonic_ns()>=cfg.absolute_deadline_ns:fail(Code.DEADLINE_EXCEEDED);break
                if name=='stdin':
                    if first_error is not None:continue
                    chunk=bytes(control._pending[:QUANTUM])
                    try:written=os.write(owners.items['stdin'].fd,chunk)
                    except BlockingIOError:continue
                    except OSError:fail(Code.IO_FAILED);close_stdin();continue
                    max_write=max(max_write,len(chunk));write_bytes+=written;control._consume(written)
                    continue
                limit=cfg.stdout_limit if name=='stdout' else cfg.stderr_limit
                amount=min(QUANTUM,limit+1-observed[name]);max_read=max(max_read,amount)
                try:block=os.read(owners.items[name].fd,amount)
                except BlockingIOError:continue
                except OSError:fail(Code.IO_FAILED);selector.unregister(key.fileobj);live_streams.discard(name);owners.close(name);continue
                read_calls+=1
                if not block:
                    selector.unregister(key.fileobj);live_streams.discard(name);owners.close(name);continue
                observed[name]+=len(block)
                if observed[name]>limit:fail(Code.STDOUT_LIMIT if name=='stdout' else Code.STDERR_LIMIT)
                keep=block[:max(0,limit-retained[name])]
                view=memoryview(keep)
                while view:
                    if time.monotonic_ns()>=cfg.absolute_deadline_ns:fail(Code.DEADLINE_EXCEEDED);break
                    try:written=os.write(owners.items[name+'Log'].fd,view[:QUANTUM])
                    except OSError:fail(Code.IO_FAILED);break
                    if written<=0:fail(Code.IO_FAILED);break
                    max_write=max(max_write,min(len(view),QUANTUM));write_bytes+=written;retained[name]+=written;view=view[written:]
                if name=='stdout' and keep and first_error is None:
                    offered+=len(keep)
                    try:callback(on_stdout_bytes,keep,control)
                    except TransportError as error:fail(Code(error.code))
                if observed[name]>limit:
                    fail(Code.STDOUT_LIMIT if name=='stdout' else Code.STDERR_LIMIT)
                    selector.unregister(key.fileobj);live_streams.discard(name);owners.close(name)
        close_stdin()
    except TransportError as error:fail(Code(error.code))
    except BaseException:fail(Code.IO_FAILED)
    finally:
        control._active=False
        # Close our input first. No signal, automatic terminal command or new
        # deadline is used while awaiting this actual direct child naturally.
        if child is not None:
            close_stdin();wait_start=time.monotonic_ns()
            try:wait_result=child.wait(timeout=max(0,(cfg.absolute_deadline_ns-wait_start)/1e9))
            except subprocess.TimeoutExpired:wait_timed_out=True;fail(Code.CHILD_UNJOINED)
            except BaseException:fail(Code.CHILD_UNJOINED)
            wait_end=time.monotonic_ns()
        owners.close_all()
    end=time.monotonic_ns()
    reaped=wait_result is not None
    if wait_result is not None and wait_result!=0:fail(Code.CHILD_NONZERO)
    if child is not None and not reaped:code=Code.CHILD_UNJOINED
    else:code=first_error
    closures_proven=all(x['closedEBADF'] for x in owners.receipts)
    if not closures_proven and code is None:code=Code.CLOSE_UNPROVEN
    if end>=cfg.absolute_deadline_ns and code is None:code=Code.DEADLINE_EXCEEDED
    receipt=dict(schemaVersion=1,passed=code is None and reaped and wait_result==0,
        code=None if code is None else code.value,firstErrorCode=None if first_error is None else first_error.value,
        startMonotonicNs=start,endMonotonicNs=end,absoluteDeadlineMonotonicNs=cfg.absolute_deadline_ns,
        deadlineExceeded=end>=cfg.absolute_deadline_ns,actualPopenPID=None if child is None else child.pid,
        spawnStartedMonotonicNs=spawn_start,spawnReturnedMonotonicNs=spawn_return,
        directNaturalWaitAttempted=wait_start is not None,waitStartMonotonicNs=wait_start,waitEndMonotonicNs=wait_end,
        actualWaitResult=wait_result,waitTimedOut=wait_timed_out,directChildReaped=reaped,liveUnjoinedRejected=child is not None and not reaped,
        stdoutActualReadBytes=observed['stdout'],stderrActualReadBytes=observed['stderr'],stdoutRetainedBytes=retained['stdout'],stderrRetainedBytes=retained['stderr'],
        stdoutDeclaredLimit=cfg.stdout_limit,stderrDeclaredLimit=cfg.stderr_limit,readCalls=read_calls,explicitReadBytes=sum(observed.values()),explicitWriteBytes=write_bytes,
        maximumReadQuantum=max_read,maximumWriteQuantum=max_write,stdinAcceptedBytes=control._accepted_bytes,stdinActualWrittenBytes=control._written,
        controlCommands=control._accepted,controlPendingBytesAtEnd=len(control._pending),callbackInvocations=callbacks,stdoutCallbackOfferedBytes=offered,
        closureReadbacks=owners.receipts,allObservedOwnedFDClosesProven=closures_proven,observedOwnedResourceCount=len(owners.receipts),
        sentSignalCalls=0,terminalCommandGeneratedByTransport=False,nonceDerivedFromStdout=False,
        implicitSpawnOSIO='unknown',completeFDOrMemoryPeak='unknown')
    return InteractiveResult(receipt,child)
